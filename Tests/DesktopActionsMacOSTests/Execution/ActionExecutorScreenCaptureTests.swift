import DesktopActions
import DesktopActionsMacOS
import XCTest

final class ActionExecutorScreenCaptureTests: XCTestCase {
  func testScreenCaptureCallsRecoveryHookWhenAccessCheckFails() async throws {
    let logs = LogRecorder()
    let tracker = ScreenRecordingTracker()
    let processRunner = TestScreenCaptureProcessRunner()
    let executor = ActionExecutor(
      configuration: ActionExecutorConfiguration(
        permissions: .init(
          onScreenRecordingRequired: {
            await tracker.markRequested()
          }),
        log: { level, message in logs.record(level, message) }
      ),
      dependencies: makeActionExecutorDependencies(
        screenCaptureProcessRunner: processRunner,
        screenCaptureAccessChecker: TestScreenCaptureAccessChecker(result: false)
      )
    )

    let outcome = try await executor.execute(.captureScreenFull)
    guard case .failure(let error) = outcome.finalResult else {
      return XCTFail("Expected failure, got: \(outcome.finalResult)")
    }
    XCTAssertEqual(error.code, .permissionDenied)
    XCTAssertEqual(error.permission, .screenRecording)
    let requested = await tracker.wasRequested
    XCTAssertTrue(requested)
    XCTAssertTrue(processRunner.receivedArguments.isEmpty)
    XCTAssertTrue(logs.contains(level: .warning, message: "Permission denied: screen-recording"))
  }

  func testGuardedScreenCaptureRejectsBeforeCallingPermissionRecovery() async {
    for action: ActionRequest in [
      .captureScreenFull, .captureScreenSelection, .captureScreenWindow,
    ] {
      let recovery = InvocationRecorder()
      let processRunner = TestScreenCaptureProcessRunner()
      let executor = ActionExecutor(
        configuration: .init(permissions: .init(onScreenRecordingRequired: { recovery.record() })),
        dependencies: makeActionExecutorDependencies(
          screenCaptureProcessRunner: processRunner,
          screenCaptureAccessChecker: TestScreenCaptureAccessChecker(result: false)))

      do {
        _ = try await executor.execute(action, beforeStep: { false })
        XCTFail("Expected cancellation from the rejected approval")
      } catch {
        XCTAssertEqual(recovery.invocationCount, 0)
        XCTAssertTrue(processRunner.receivedArguments.isEmpty)
      }
    }
  }

  func testGuardedScreenCaptureRechecksApprovalAfterPermissionRecovery() async {
    for revokeDuringRecovery in [false, true] {
      let tracker = ScreenRecordingTracker()
      let checks = InvocationRecorder()
      let processRunner = TestScreenCaptureProcessRunner()
      let executor = ActionExecutor(
        configuration: .init(
          permissions: .init(onScreenRecordingRequired: { await tracker.markRequested() })),
        dependencies: makeActionExecutorDependencies(
          screenCaptureProcessRunner: processRunner,
          screenCaptureAccessChecker: TestScreenCaptureAccessChecker(result: false)))

      do {
        let outcome = try await executor.execute(
          .captureScreenFull,
          beforeStep: {
            checks.record()
            let requested = await tracker.wasRequested
            return !revokeDuringRecovery || !requested
          })
        XCTAssertFalse(revokeDuringRecovery)
        guard case .failure(let error) = outcome.finalResult else {
          return XCTFail("Expected Screen Recording denial")
        }
        XCTAssertEqual(error.code, .permissionDenied)
        XCTAssertEqual(error.permission, .screenRecording)
      } catch {
        XCTAssertTrue(revokeDuringRecovery)
      }
      let requested = await tracker.wasRequested
      XCTAssertTrue(requested)
      XCTAssertEqual(checks.invocationCount, 2)
      XCTAssertTrue(processRunner.receivedArguments.isEmpty)
    }
  }

  func testScreenCapturePassesPlannedArgumentsToRunner() async throws {
    let expectations: [(action: ActionRequest, arguments: [String])] = [
      (.captureScreenFull, ["-p", "-x"]),
      (.captureScreenSelection, ["-p", "-i"]),
      (.captureScreenWindow, ["-p", "-i", "-W"]),
    ]

    for expectation in expectations {
      let processRunner = TestScreenCaptureProcessRunner()
      let executor = ActionExecutor(
        configuration: .init(),
        dependencies: makeActionExecutorDependencies(screenCaptureProcessRunner: processRunner)
      )

      let outcome = try await executor.execute(expectation.action)

      XCTAssertEqual(outcome.finalResult, .success)
      XCTAssertEqual(processRunner.receivedArguments, [expectation.arguments])
    }
  }

  func testCancelledScreenCaptureDoesNotLogLateProcessFailure() async throws {
    let logs = LogRecorder()
    let executor = ActionExecutor(
      configuration: .init(log: { level, message in logs.record(level, message) }),
      dependencies: makeActionExecutorDependencies(
        screenCaptureProcessRunner: CancelledScreenCaptureRunner()
      )
    )
    let task = Task { try await executor.execute(.captureScreenFull) }
    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      XCTAssertFalse(
        logs.contains(level: .error, message: "Screen capture failed with termination status 2")
      )
    }
  }

  func testScreenCaptureProcessFailureReturnsScreenCaptureFailed() async throws {
    let logs = LogRecorder()
    let executor = ActionExecutor(
      configuration: .init(log: { level, message in logs.record(level, message) }),
      dependencies: makeActionExecutorDependencies(
        screenCaptureProcessRunner: TestScreenCaptureProcessRunner(
          result: .failure(.init(terminationStatus: 2))
        )
      )
    )

    let outcome = try await executor.execute(.captureScreenFull)
    guard case .failure(let error) = outcome.finalResult else {
      return XCTFail("Expected failure, got: \(outcome.finalResult)")
    }
    XCTAssertEqual(error.code, .screenCaptureFailed)
    XCTAssertEqual(error.diagnosticMessage, "Screen capture failed with termination status 2")
    XCTAssertTrue(
      logs.contains(level: .error, message: "Screen capture failed with termination status 2")
    )
  }

  func testScreenCaptureProcessFailureWithoutStatusReturnsScreenCaptureFailed() async throws {
    let logs = LogRecorder()
    let executor = ActionExecutor(
      configuration: .init(log: { level, message in logs.record(level, message) }),
      dependencies: makeActionExecutorDependencies(
        screenCaptureProcessRunner: TestScreenCaptureProcessRunner(
          result: .failure(.init(terminationStatus: nil))
        )
      )
    )

    let outcome = try await executor.execute(.captureScreenFull)
    XCTAssertEqual(outcome.finalResult, .failure(.screenCaptureFailed("Screen capture failed")))
    XCTAssertTrue(logs.contains(level: .error, message: "Screen capture failed"))
  }
}

private actor ScreenRecordingTracker {
  private(set) var requested = false

  func markRequested() {
    requested = true
  }

  var wasRequested: Bool {
    requested
  }
}

private struct CancelledScreenCaptureRunner: ScreenCaptureProcessRunning {
  func run(arguments _: [String]) async throws {
    withUnsafeCurrentTask { $0?.cancel() }
    throw ScreenCaptureProcessFailure(terminationStatus: 2)
  }
}
