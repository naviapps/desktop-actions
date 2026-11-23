import DesktopActions
import Synchronization
import XCTest

final class ActionSequenceTests: XCTestCase {
  private static let success = ActionExecutionReport(result: .success)
  private static let failure = ActionExecutionReport(result: .failure(.notFound("fixture")))

  func testOrderAndExplicitContinuationPreserveEveryResult() async throws {
    let runner = try ActionRunner(maximumConcurrentExecutions: 1, timeout: .seconds(2))
    let calls = Calls()
    let report = await runner.runSequence([.copy, .paste], failureBehavior: .continue) { action in
      await calls.append(action)
      return action == .copy ? Self.failure : Self.success
    }
    let observed = await calls.actions
    XCTAssertEqual(observed, [.copy, .paste])
    XCTAssertEqual(report.status, .completed)
    XCTAssertEqual(report.results, [.completed(Self.failure), .completed(Self.success)])
    XCTAssertFalse(report.allActionsSucceeded)
    let equivalent = await runner.runSequence([.copy, .paste], failureBehavior: .continue) {
      $0 == .copy ? Self.failure : Self.success
    }
    let reversed = await runner.runSequence([.paste, .copy], failureBehavior: .continue) {
      $0 == .copy ? Self.failure : Self.success
    }
    XCTAssertEqual(report, equivalent)
    XCTAssertNotEqual(report, reversed)
  }

  func testStopPolicyDoesNotStartTheNextAction() async throws {
    let runner = try ActionRunner(maximumConcurrentExecutions: 1, timeout: .seconds(2))
    let calls = Calls()
    let report = await runner.runSequence([.copy, .paste], failureBehavior: .stop) { action in
      await calls.append(action)
      return Self.failure
    }
    let observed = await calls.actions
    XCTAssertEqual(observed, [.copy])
    XCTAssertEqual(report.status, .stopped)
    XCTAssertFalse(report.allActionsSucceeded)
  }

  func testAlreadyCancelledSequenceDoesNotInvokeWork() async throws {
    let runner = try ActionRunner(maximumConcurrentExecutions: 1, timeout: .seconds(2))
    let task = Task { @Sendable in
      withUnsafeCurrentTask { $0?.cancel() }
      return await runner.runSequence([.copy, .paste], failureBehavior: .continue) { _ in
        XCTFail("Cancelled sequence invoked an action")
        return ActionSequenceTests.success
      }
    }
    let report = await task.value
    XCTAssertEqual(report.status, .cancelled)
    XCTAssertTrue(report.results.isEmpty)
  }

  func testEmptySequenceIsSuccessfulWithoutAnOperation() async throws {
    let runner = try ActionRunner(maximumConcurrentExecutions: 1, timeout: .seconds(2))
    let report = await runner.runSequence([], failureBehavior: .stop) { _ in
      XCTFail("Empty sequence invoked an action")
      return Self.success
    }
    XCTAssertEqual(report.status, .completed)
    XCTAssertTrue(report.results.isEmpty)
    XCTAssertTrue(report.allActionsSucceeded)
  }

  func testCancellationWhileSecondWorkerRunsKeepsTheFirstDelivery() async throws {
    let runner = try ActionRunner(maximumConcurrentExecutions: 1, timeout: .seconds(5))
    let secondStarted = expectation(description: "second worker entered")
    let delivered = expectation(description: "sequence delivered while second worker was waiting")
    let operationReturned = expectation(description: "cancelled worker observed the signal")
    let gate = Gate()
    let calls = Calls()
    let claims = Claims()
    let sequence = Task { @Sendable in
      let report = await runner.runSequence(
        [.copy, .paste, .cut], failureBehavior: .continue,
        exemptFromTimeout: { action in
          claims.append(action)
          return true
        },
        operation: { action in
          await calls.append(action)
          if action == .paste {
            secondStarted.fulfill()
            await gate.wait()
            XCTAssertTrue(Task.isCancelled)
            operationReturned.fulfill()
            return ActionSequenceTests.failure
          }
          return ActionSequenceTests.success
        })
      delivered.fulfill()
      return report
    }
    await fulfillment(of: [secondStarted], timeout: 2)
    sequence.cancel()
    await fulfillment(of: [delivered], timeout: 2)
    let busy = await runner.run(.cut) { _ in
      XCTFail("The second worker still owns capacity")
      return Self.success
    }
    XCTAssertEqual(busy, .busy)
    await gate.open()
    await fulfillment(of: [operationReturned], timeout: 2)
    let report = await sequence.value
    XCTAssertEqual(report.status, .cancelled)
    XCTAssertEqual(report.results, [.completed(Self.success), .cancelled])
    XCTAssertFalse(report.allActionsSucceeded)
    XCTAssertEqual(claims.actions, [.copy, .paste])
    let observed = await calls.actions
    XCTAssertEqual(observed, [.copy, .paste])
    await ActionTestFixtures.assertExecutionCapacityReleased(runner, report: Self.success)
  }

  func testCancellationInTheTimeoutSelectorKeepsProgressAndSkipsTheSecondEffect() async throws {
    let runner = try ActionRunner(maximumConcurrentExecutions: 1, timeout: .seconds(5))
    let calls = Calls()
    let claims = Claims()
    let caller = Task { @Sendable in
      await runner.runSequence(
        [.copy, .paste, .cut], failureBehavior: .continue,
        exemptFromTimeout: { action in
          claims.append(action)
          if action == .paste { withUnsafeCurrentTask { $0?.cancel() } }
          return true
        },
        operation: { action in
          await calls.append(action)
          return ActionSequenceTests.success
        })
    }
    let report = await caller.value
    XCTAssertEqual(report.status, .cancelled)
    XCTAssertEqual(report.results, [.completed(Self.success), .cancelled])
    XCTAssertFalse(report.allActionsSucceeded)
    XCTAssertEqual(claims.actions, [.copy, .paste])
    let observed = await calls.actions
    XCTAssertEqual(observed, [.copy])
    let next = await runner.run(.cut) { _ in Self.success }
    XCTAssertEqual(next, .completed(Self.success))
  }

  func testTimeoutNeverStartsAnotherActionWhileNativeWorkIsUnacknowledged() async throws {
    let runner = try ActionRunner(maximumConcurrentExecutions: 1, timeout: .seconds(1))
    let gate = Gate()
    let calls = Calls()
    let claims = Claims()
    let report = await runner.runSequence(
      [.copy, .paste], failureBehavior: .continue,
      exemptFromTimeout: { action in
        claims.append(action)
        return false
      },
      operation: { action in
        await calls.append(action)
        await gate.wait()
        return Self.success
      }
    )
    XCTAssertEqual(report.status, .timedOut)
    XCTAssertEqual(report.results, [.timedOut])
    XCTAssertFalse(report.allActionsSucceeded)
    XCTAssertEqual(claims.actions, [.copy])
    let observed = await calls.actions
    XCTAssertEqual(observed, [.copy])
    let busy = await runner.run(.paste) { _ in
      XCTFail("Timed-out worker released capacity before acknowledging")
      return Self.success
    }
    XCTAssertEqual(busy, .busy)
    await gate.open()
  }

  private final class Claims: Sendable {
    private let recorded = Mutex<[ActionRequest]>([])

    var actions: [ActionRequest] { recorded.withLock { $0 } }

    func append(_ action: ActionRequest) { recorded.withLock { $0.append(action) } }
  }

  private actor Calls {
    var actions: [ActionRequest] = []
    func append(_ action: ActionRequest) { actions.append(action) }
  }

  private actor Gate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
      guard !opened else { return }
      await withCheckedContinuation { continuation = $0 }
    }
    func open() {
      opened = true
      continuation?.resume()
      continuation = nil
    }
  }
}
