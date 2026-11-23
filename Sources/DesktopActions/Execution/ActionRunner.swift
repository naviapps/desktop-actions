import CDesktopActions
import Dispatch
import Synchronization

/// Bounds actual native workers, including workers still acknowledging cancellation.
/// Hosts choose capacity, deadlines and any interactive timeout exemptions.
public final class ActionRunner: Sendable {
  /// Invalid host-supplied execution policy.
  public enum ConfigurationError: Error, Sendable, Equatable {
    /// Capacity must be positive.
    case invalidCapacity
    /// Timeout must be positive and representable in unsigned nanoseconds.
    case invalidTimeout
  }
  typealias WorkerLauncher =
    @Sendable (TaskPriority, @escaping @Sendable () async -> Void) -> Task<Void, Never>

  private let pool: Pool
  private let launchWorker: WorkerLauncher

  /// Creates a reusable runner with explicit host policy and nanosecond precision.
  public convenience init(maximumConcurrentExecutions: Int, timeout: Duration) throws {
    try self.init(
      maximumConcurrentExecutions: maximumConcurrentExecutions, timeout: timeout,
      clock: ContinuousClock())
  }

  init(
    maximumConcurrentExecutions: Int, timeout: Duration,
    clock: some Clock<Duration> = ContinuousClock(),
    launchWorker: @escaping WorkerLauncher = { priority, operation in
      Task.detached(priority: priority, operation: operation)
    }
  ) throws {
    guard maximumConcurrentExecutions > 0 else { throw ConfigurationError.invalidCapacity }
    guard let nanoseconds = Self.nanoseconds(timeout), nanoseconds > 0 else {
      throw ConfigurationError.invalidTimeout
    }
    pool = Pool(maximum: maximumConcurrentExecutions, timeout: nanoseconds, clock: clock)
    self.launchWorker = launchWorker
  }

  /// Runs one action without releasing capacity merely because its caller stopped waiting.
  /// The worker starts only after its cancellation handle is registered. Terminal delivery
  /// runs independently of the worker's cancellation handlers. Once admitted, the operation
  /// must cooperate with cancellation where its OS resource allows it.
  public func run(
    _ action: ActionRequest, exemptFromTimeout: Bool = false,
    operation:
      @escaping @Sendable (ActionRequest) async throws(CancellationError) -> ActionExecutionReport
  ) async -> ActionRunResult {
    guard !Task.isCancelled else { return .cancelled }
    let id = pool.reserve(exempt: exemptFromTimeout)
    guard id != 0 else { return .busy }
    let completion = Delivery(pool: pool, id: id)
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        completion.install(continuation)
        let (startSignal, startup) = AsyncStream<Void>.makeStream(
          bufferingPolicy: .bufferingNewest(1))
        let worker = launchWorker(Task.currentPriority) { [pool] in
          var admission = startSignal.makeAsyncIterator()
          guard await admission.next() != nil else {
            completion.cancel()
            _ = pool.finish(id)
            return
          }
          if pool.timeout(id) != 0 {
            completion.deliver(.timedOut)
            _ = pool.finish(id)
            return
          }
          guard pool.active(id) else {
            _ = pool.finish(id)
            return
          }
          do {
            try Task.checkCancellation()
            let outcome = try await operation(action)
            switch pool.finish(id) {
            case 1: completion.deliver(.completed(outcome))
            case 3: completion.deliver(.timedOut)
            default: break
            }
          } catch {
            completion.cancel()
            _ = pool.finish(id)
          }
        }
        completion.install(worker: worker)
        startup.yield(())
        startup.finish()
        if pool.deadline(id) != nil {
          let timer = Task.detached { [pool] in
            while !Task.isCancelled, let deadline = pool.deadline(id) {
              if pool.timeout(id) != 0 {
                completion.deliver(.timedOut)
                return
              }
              guard pool.active(id) else { return }
              do { try await pool.sleep(until: deadline) } catch { return }
            }
          }
          completion.install(timer: timer)
        }
      }
    } onCancel: {
      completion.cancel()
    }
  }

  private static func nanoseconds(_ duration: Duration) -> UInt64? {
    let c = duration.components
    guard let seconds = UInt64(exactly: c.seconds), let attoseconds = UInt64(exactly: c.attoseconds)
    else { return nil }
    let (whole, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
    let (total, additionOverflow) = whole.addingReportingOverflow(attoseconds / 1_000_000_000)
    return overflow || additionOverflow ? nil : total
  }
  private static func duration(_ nanoseconds: UInt64) -> Duration {
    .seconds(Int64(nanoseconds / 1_000_000_000)) + .nanoseconds(Int64(nanoseconds % 1_000_000_000))
  }
  private final class Pool: @unchecked Sendable {
    private let owner: OpaquePointer
    private let now: @Sendable () -> UInt64
    private let sleepUntil: @Sendable (UInt64) async throws -> Void
    init(maximum: Int, timeout: UInt64, clock: some Clock<Duration>) {
      precondition(
        desktop_actions_abi_version() == DESKTOP_ACTIONS_ABI_VERSION,
        "Unsupported native DesktopActions ABI")
      let origin = clock.now
      now = { ActionRunner.nanoseconds(origin.duration(to: clock.now)) ?? UInt64.max }
      sleepUntil = { deadline in
        try await clock.sleep(
          until: origin.advanced(by: ActionRunner.duration(deadline)), tolerance: nil)
      }
      owner = desktop_actions_execution_create(maximum, timeout)!
    }
    deinit { desktop_actions_execution_destroy(owner) }
    func sleep(until deadline: UInt64) async throws { try await sleepUntil(deadline) }
    func reserve(exempt: Bool) -> UInt64 {
      desktop_actions_execution_reserve(owner, now(), exempt ? 1 : 0)
    }
    func active(_ id: UInt64) -> Bool { desktop_actions_execution_active(owner, id) == 1 }
    func deadline(_ id: UInt64) -> UInt64? {
      let value = desktop_actions_execution_deadline(owner, id)
      return value == 0 ? nil : value
    }
    func cancel(_ id: UInt64) -> UInt32 { desktop_actions_execution_cancel(owner, id, now()) }
    func timeout(_ id: UInt64) -> UInt32 { desktop_actions_execution_timeout(owner, id, now()) }
    func finish(_ id: UInt64) -> UInt32 { desktop_actions_execution_finish(owner, id, now()) }
  }
  /// Language scheduling only: Rust grants each terminal delivery exactly once.
  /// The pending value handles cancellation before continuation installation.
  private final class Delivery: Sendable {
    private struct State {
      var continuation: CheckedContinuation<ActionRunResult, Never>?
      var pending: ActionRunResult?
      var worker: Task<Void, Never>?
      var timer: Task<Void, Never>?
    }
    private let state = Mutex(State())
    private let pool: Pool
    private let id: UInt64
    init(pool: Pool, id: UInt64) {
      self.pool = pool
      self.id = id
    }
    func install(_ continuation: CheckedContinuation<ActionRunResult, Never>) {
      let pending = state.withLock { state -> ActionRunResult? in
        if let pending = state.pending {
          state.pending = nil
          return pending
        }
        state.continuation = continuation
        return nil
      }
      if let pending { continuation.resume(returning: pending) }
    }
    func install(worker: Task<Void, Never>) {
      let cancel = state.withLock { state in
        guard pool.active(id) else { return true }
        state.worker = worker
        return false
      }
      if cancel { worker.cancel() }
    }
    func install(timer: Task<Void, Never>) {
      let cancel = state.withLock { state in
        guard pool.active(id) else { return true }
        state.timer = timer
        return false
      }
      if cancel { timer.cancel() }
    }
    func cancel() {
      switch pool.cancel(id) {
      case 2: deliver(.cancelled)
      case 3: deliver(.timedOut)
      default: break
      }
    }
    func deliver(_ outcome: ActionRunResult) {
      let (continuation, worker, timer) = state.withLock { state in
        let result = (state.continuation, state.worker, state.timer)
        if state.continuation == nil { state.pending = outcome }
        state.continuation = nil
        state.worker = nil
        state.timer = nil
        return result
      }
      timer?.cancel()
      if case .completed = outcome {
      } else if let worker {
        // Task.cancel marks the task first, then can run arbitrary cancellation handlers.
        // Await the mark so the caller can release suspended work without allowing effects.
        let cancellationReturned = Mutex(false)
        DispatchQueue.global().async {
          worker.cancel()
          cancellationReturned.withLock { $0 = true }
        }
        if let continuation {
          Task.detached {
            while !worker.isCancelled && !cancellationReturned.withLock({ $0 }) {
              try? await Task.sleep(for: .milliseconds(1))
            }
            continuation.resume(returning: outcome)
          }
        }
        return
      }
      continuation?.resume(returning: outcome)
    }
  }
}
