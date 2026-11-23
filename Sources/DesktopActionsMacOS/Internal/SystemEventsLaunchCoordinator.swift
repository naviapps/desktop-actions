import AppKit
import DesktopApplicationsMacOS
import Foundation

package actor SystemEventsLaunchCoordinator {
  private static let appURL = URL(
    fileURLWithPath: "/System/Library/CoreServices/System Events.app")
  static let bundleIdentifier = "com.apple.systemevents"
  private static let maxRunningChecks = 20
  private static let runningCheckInterval: UInt64 = 50_000_000

  private let isRunning: @Sendable () async -> Bool
  private let launch: @Sendable () async -> Void
  private let sleep: @Sendable (UInt64) async -> Void
  private(set) var launchTask: Task<Void, Never>?
  private var launchIdentifier: UUID?
  private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

  var waitingCallerCount: Int { waiters.count }

  package init(
    isRunning: @escaping @Sendable () async -> Bool,
    launch: @escaping @Sendable () async -> Void,
    sleep: @escaping @Sendable (UInt64) async -> Void
  ) {
    self.isRunning = isRunning
    self.launch = launch
    self.sleep = sleep
  }

  package func ensureRunning() async -> Bool {
    let waiter = UUID()
    let result = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(returning: false)
          return
        }
        waiters[waiter] = continuation
        if launchTask == nil {
          let identifier = UUID()
          launchIdentifier = identifier
          launchTask = Task {
            let running = await launchAndWait()
            finish(identifier, running: running)
          }
        }
      }
    } onCancel: {
      Task { await self.cancel(waiter) }
    }
    return !Task.isCancelled && result
  }

  private func cancel(_ waiter: UUID) {
    guard let continuation = waiters.removeValue(forKey: waiter) else { return }
    if waiters.isEmpty {
      launchTask?.cancel()
      launchTask = nil
      launchIdentifier = nil
    }
    continuation.resume(returning: false)
  }

  private func finish(_ identifier: UUID, running: Bool) {
    guard launchIdentifier == identifier else { return }
    let completed = waiters.values
    waiters.removeAll()
    launchTask = nil
    launchIdentifier = nil
    for continuation in completed {
      continuation.resume(returning: running)
    }
  }

  private func launchAndWait() async -> Bool {
    guard !Task.isCancelled else { return false }
    if await isRunning() { return !Task.isCancelled }
    guard !Task.isCancelled else { return false }
    await launch()
    for _ in 0..<Self.maxRunningChecks {
      guard !Task.isCancelled else { return false }
      if await isRunning() { return !Task.isCancelled }
      guard !Task.isCancelled else { return false }
      await sleep(Self.runningCheckInterval)
    }
    guard !Task.isCancelled else { return false }
    let running = await isRunning()
    return !Task.isCancelled && running
  }

  @MainActor
  static func launchSystemEvents() async {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false

    _ = try? await ApplicationManager().openApplication(
      at: Self.appURL, configuration: configuration)
  }
}
