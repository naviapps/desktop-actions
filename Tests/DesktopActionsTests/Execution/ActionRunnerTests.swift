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
    let runner = try ActionRunner(maximumConcurrentExecutions: 1, timeout: .milliseconds(200))
    let started = expectation(description: "worker started")
    let gate = Gate()
    let first = Task {
      await runner.run(.copy) { _ in
        started.fulfill()
        await gate.wait()
        return Self.success
      }
    }
    await fulfillment(of: [started], timeout: 2)
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

  func testCancellationReturnsPromptlyButCannotOverbookAWorker() async throws {
    let runner = try ActionRunner(maximumConcurrentExecutions: 1, timeout: .seconds(10))
    let started = expectation(description: "worker started")
    let gate = Gate()
    let first = Task {
      await runner.run(.copy) { _ in
        started.fulfill()
        await gate.wait()
        return Self.success
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

    let caller = Task {
      let outcome = await runner.run(.copy, exemptFromTimeout: true) { _ in
        await withTaskCancellationHandler {
          started.fulfill()
          await workerGate.wait()
        } onCancel: {
          handlerEntered.fulfill()
          handlerGate.wait()
        }
        return Self.success
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
    let operationRan = Mutex(false)
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

    let caller = Task {
      await runner.run(.copy) { _ in
        operationRan.withLock { $0 = true }
        await finishOperation.wait()
        return Self.success
      }
    }
    let outcome = await caller.value
    await finishOperation.open()
    XCTAssertEqual(outcome, .cancelled)
    XCTAssertFalse(
      operationRan.withLock { $0 },
      "An action must not run before its worker can receive cancellation.")
    await ActionTestFixtures.assertExecutionCapacityReleased(runner, report: Self.success)
  }

  func testAlreadyCancelledCallerNeverEntersNativeOperation() async throws {
    let runner = try ActionRunner(maximumConcurrentExecutions: 1, timeout: .seconds(1))
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return await runner.run(.copy) { _ in
        XCTFail("Cancelled caller executed an action")
        return Self.success
      }
    }
    let outcome = await task.value
    XCTAssertEqual(outcome, .cancelled)
    await ActionTestFixtures.assertExecutionCapacityReleased(runner, report: Self.success)
  }

  func testHostCanExemptInteractiveWorkFromItsDefaultTimeout() async throws {
    let runner = try ActionRunner(maximumConcurrentExecutions: 1, timeout: .milliseconds(10))
    let gate = Gate()
    let started = expectation(description: "interactive worker started")
    let task = Task {
      await runner.run(.captureScreenSelection, exemptFromTimeout: true) { _ in
        started.fulfill()
        await gate.wait()
        return Self.success
      }
    }
    await fulfillment(of: [started], timeout: 2)
    try await Task.sleep(for: .milliseconds(30))
    await gate.open()
    let outcome = await task.value
    XCTAssertEqual(outcome, .completed(Self.success))
  }

  func testCancellationAndImmediateCompletionDoNotLoseOrRepeatDelivery() async throws {
    let runner = try ActionRunner(maximumConcurrentExecutions: 32, timeout: .seconds(2))
    for _ in 0..<32 {
      let task = Task { await runner.run(.copy) { _ in Self.success } }
      task.cancel()
      let outcome = await task.value
      switch outcome {
      case .completed, .cancelled: break
      default: XCTFail("Unexpected terminal delivery: \(outcome)")
      }
    }
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
