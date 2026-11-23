import Synchronization
import XCTest

@testable import DesktopActions

final class ActionRunnerTests: XCTestCase {
  private static let success = ActionExecutionReport(attempts: [
    .init(requiredPermissions: [], isFallback: false, result: .success)
  ])

  func testPolicyRejectsInvalidCapacityAndTimeoutInsteadOfChangingIt() {
    for maximum in [0, -1] {
      XCTAssertThrowsError(
        try ActionRunner(maximumConcurrentExecutions: maximum, timeout: .seconds(1))
      ) {
        XCTAssertEqual($0 as? ActionRunner.ConfigurationError, .invalidCapacity)
      }
    }
    for timeout: Duration in [.zero, .nanoseconds(-1), .seconds(Int64.max)] {
      XCTAssertThrowsError(try ActionRunner(maximumConcurrentExecutions: 1, timeout: timeout)) {
        XCTAssertEqual($0 as? ActionRunner.ConfigurationError, .invalidTimeout)
      }
    }
  }

  func testTimeoutRetainsCapacityUntilUncooperativeWorkerActuallyReturns() async throws {
    let timerSleeping = expectation(description: "deadline timer started sleeping")
    timerSleeping.assertForOverFulfill = false
    let clock = ActionTestClock(onSleep: { timerSleeping.fulfill() })
    let runner = try ActionRunner(
      maximumConcurrentExecutions: 1, timeout: .milliseconds(200), clock: clock)
    let started = expectation(description: "worker started")
    let gate = Gate()
    let first = Task { @Sendable in
      await runner.run(.copy) { _ in
        started.fulfill()
        await gate.wait()
        return ActionRunnerTests.success
      }
    }
    await fulfillment(of: [started, timerSleeping], timeout: 2)
    clock.advance(by: .milliseconds(200))
    let outcome = await first.value
    XCTAssertEqual(outcome, .timedOut)
    let occupied = await runner.run(.paste) { _ in
      XCTFail("Capacity was released before worker acknowledgement")
      return Self.success
    }
    XCTAssertEqual(occupied, .busy)
    await gate.open()
    await ActionTestFixtures.assertExecutionCapacityReleased(runner, report: Self.success)
  }

  func testWorkerDoesNotStartEffectsAtItsDeadline() async throws {
    let clock = ActionTestClock()
    let ran = OperationProbe()
    let workerFinished = expectation(description: "expired worker returned")
    let runner = try ActionRunner(
      maximumConcurrentExecutions: 1, timeout: .nanoseconds(1), clock: clock
    ) { priority, operation in
      clock.advance(by: .nanoseconds(1))
      return Task.detached(priority: priority) {
        await operation()
        workerFinished.fulfill()
      }
    }

    let outcome = await runner.run(.copy) { _ in
      ran.record()
      return ActionRunnerTests.success
    }
    XCTAssertEqual(outcome, .timedOut)
    await fulfillment(of: [workerFinished], timeout: 2)
    XCTAssertFalse(ran.didRun)
  }

  func testCancellationReturnsPromptlyButCannotOverbookAWorker() async throws {
    let runner = try ActionRunner(maximumConcurrentExecutions: 1, timeout: .seconds(10))
    let started = expectation(description: "worker started")
    let gate = Gate()
    let first = Task { @Sendable in
      await runner.run(.copy) { _ in
        started.fulfill()
        await gate.wait()
        return ActionRunnerTests.success
      }
    }
    await fulfillment(of: [started], timeout: 2)
    first.cancel()
    let outcome = await first.value
    XCTAssertEqual(outcome, .cancelled)
    let occupied = await runner.run(.paste) { _ in
      XCTFail("Cancelled worker still holds capacity")
      return Self.success
    }
    XCTAssertEqual(occupied, .busy)
    await gate.open()
    await ActionTestFixtures.assertExecutionCapacityReleased(runner, report: Self.success)
  }

  func testCancellationDeliveryDoesNotWaitForTheWorkersCancellationHandler() async throws {
    let runner = try ActionRunner(maximumConcurrentExecutions: 1, timeout: .seconds(5))
    let started = expectation(description: "worker installed its cancellation handler")
    let handlerEntered = expectation(description: "worker cancellation handler entered")
    let cancellationReturned = expectation(description: "caller task cancellation returned")
    let deliveryReturned = expectation(description: "terminal delivery returned")
    let workerGate = Gate()
    let handlerGate = DispatchSemaphore(value: 0)

    let caller = Task { @Sendable in
      let outcome = await runner.run(.copy, exemptFromTimeout: true) { _ in
        await withTaskCancellationHandler {
          started.fulfill()
          await workerGate.wait()
        } onCancel: {
          handlerEntered.fulfill()
          handlerGate.wait()
        }
        return ActionRunnerTests.success
      }
      deliveryReturned.fulfill()
      return outcome
    }
    await fulfillment(of: [started], timeout: 2)
    let signal = Task.detached {
      caller.cancel()
      cancellationReturned.fulfill()
    }
    await fulfillment(of: [handlerEntered, cancellationReturned, deliveryReturned], timeout: 2)
    let occupied = await runner.run(.paste) { _ in
      XCTFail("A worker still acknowledging cancellation holds capacity.")
      return Self.success
    }
    XCTAssertEqual(occupied, .busy)

    handlerGate.signal()
    await signal.value
    let outcome = await caller.value
    XCTAssertEqual(outcome, .cancelled)
    await workerGate.open()
    await ActionTestFixtures.assertExecutionCapacityReleased(runner, report: Self.success)
  }

  func testCancellationBeforeWorkerHandleRegistrationPreventsAction() async throws {
    let cancelDuringFirstLaunch = Mutex(true)
    let operationRan = OperationProbe()
    let finishOperation = Gate()
    let runner = try ActionRunner(maximumConcurrentExecutions: 1, timeout: .seconds(10)) {
      priority, operation in
      // Start the detached worker before giving the runner its cancellation handle.
      let worker = Task.immediateDetached(priority: priority, operation: operation)
      if cancelDuringFirstLaunch.withLock({ first in
        defer { first = false }
        return first
      }) {
        withUnsafeCurrentTask { $0?.cancel() }
      }
      return worker
    }

    let caller = Task { @Sendable in
      await runner.run(.copy) { _ in
        operationRan.record()
        await finishOperation.wait()
        return ActionRunnerTests.success
      }
    }
    let outcome = await caller.value
    await finishOperation.open()
    XCTAssertEqual(outcome, .cancelled)
    XCTAssertFalse(
      operationRan.didRun,
      "An action must not run before its worker can receive cancellation.")
    await ActionTestFixtures.assertExecutionCapacityReleased(runner, report: Self.success)
  }

  func testAlreadyCancelledCallerNeverEntersNativeOperation() async throws {
    let runner = try ActionRunner(maximumConcurrentExecutions: 1, timeout: .seconds(1))
    let task = Task { @Sendable in
      withUnsafeCurrentTask { $0?.cancel() }
      return await runner.run(.copy) { _ in
        XCTFail("Cancelled caller executed an action")
        return ActionRunnerTests.success
      }
    }
    let outcome = await task.value
    XCTAssertEqual(outcome, .cancelled)
    await ActionTestFixtures.assertExecutionCapacityReleased(runner, report: Self.success)
  }

  func testHostCanExemptInteractiveWorkFromItsDefaultTimeout() async throws {
    let clock = ActionTestClock()
    let runner = try ActionRunner(
      maximumConcurrentExecutions: 1, timeout: .milliseconds(10), clock: clock)
    let gate = Gate()
    let started = expectation(description: "interactive worker started")
    let task = Task { @Sendable in
      await runner.run(.captureScreenSelection, exemptFromTimeout: true) { _ in
        started.fulfill()
        await gate.wait()
        return ActionRunnerTests.success
      }
    }
    await fulfillment(of: [started], timeout: 2)
    clock.advance(by: .milliseconds(30))
    await gate.open()
    let outcome = await task.value
    XCTAssertEqual(outcome, .completed(Self.success))
  }

  func testCancellationAndImmediateCompletionDoNotLoseOrRepeatDelivery() async throws {
    let runner = try ActionRunner(maximumConcurrentExecutions: 32, timeout: .seconds(2))
    for _ in 0..<32 {
      let task = Task { @Sendable in
        await runner.run(.copy) { _ in ActionRunnerTests.success }
      }
      task.cancel()
      let outcome = await task.value
      switch outcome {
      case .completed, .cancelled: break
      default: XCTFail("Unexpected terminal delivery: \(outcome)")
      }
    }
  }

  private final class OperationProbe: Sendable {
    private let ran = Mutex(false)

    var didRun: Bool { ran.withLock { $0 } }

    func record() { ran.withLock { $0 = true } }
  }

  /// A deliberately uncooperative worker fixture: cancellation does not resume it.
  private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
      if opened { return }
      await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
      opened = true
      let pending = waiters
      waiters = []
      for waiter in pending { waiter.resume() }
    }
  }
}
