import ApplicationServices
import DesktopActions
import DesktopActionsMacOS
import XCTest

final class ActionExecutorAppleScriptTests: XCTestCase {
  func testNotificationCenterPreflightDenialsDoNotSendF8() async throws {
    for permission in [ActionPermission.accessibility, .automation] {
      let keys = TestKeyEventPoster()
      let script = RecordingAppleScriptExecutor()
      let launcher = TestSystemEventsLauncher()
      let recovery = AutomationDeniedRecorder()
      let executor = ActionExecutor(
        configuration: .init(
          permissions: .init(
            ensureAccessibility: { permission != .accessibility },
            ensureAutomation: { permission != .automation },
            onAutomationDenied: { number in
              await recovery.record(appleScriptErrorNumber: number)
            })),
        dependencies: makeActionExecutorDependencies(
          keyEventPoster: keys, appleScriptExecutor: script, systemEventsLauncher: launcher))

      let report = try await executor.execute(.showNotificationCenter)

      XCTAssertTrue(keys.postedEvents.isEmpty, "Notification Center must not send F8 on denial")
      XCTAssertEqual(report.finalResult, .failure(.permissionDenied(permission)))
      XCTAssertEqual(report.attempts.count, 1)
      XCTAssertFalse(report.didAttemptFallback)
      XCTAssertEqual(script.invocationCount, 0)
      let launchCount = await launcher.invocationCount
      XCTAssertEqual(launchCount, permission == .automation ? 1 : 0)
      let recovered = await recovery.called
      let errorNumber = await recovery.appleScriptErrorNumber
      XCTAssertEqual(recovered, permission == .automation)
      XCTAssertNil(errorNumber)
    }
  }

  func testNotificationCenterKeepsPermittedScriptResultsWithoutSendingF8() async throws {
    let denied = Int(errAEEventNotPermitted)
    let cases: [(Result<Void, AppleScriptExecutionFailure>, ActionResult, Int?)] = [
      (.success(()), .success, nil),
      (
        .failure(.init(message: "Fixture menu item unavailable")),
        .failure(.appleScriptFailed("Fixture menu item unavailable")), nil
      ),
      (
        .failure(.init(appleScriptErrorNumber: denied)),
        .failure(.automationPermissionDenied(appleScriptErrorNumber: denied)), denied
      ),
    ]

    for (scriptResult, expected, expectedRecovery) in cases {
      let keys = TestKeyEventPoster()
      let script = RecordingAppleScriptExecutor(result: scriptResult)
      let recovery = AutomationDeniedRecorder()
      let executor = ActionExecutor(
        configuration: .init(
          permissions: .init(
            ensureAccessibility: { true },
            ensureAutomation: { true },
            onAutomationDenied: { number in
              await recovery.record(appleScriptErrorNumber: number)
            })),
        dependencies: makeActionExecutorDependencies(
          keyEventPoster: keys, appleScriptExecutor: script))

      let report = try await executor.execute(.showNotificationCenter)

      XCTAssertTrue(
        keys.postedEvents.isEmpty, "Notification Center must not send F8 after its script")
      XCTAssertEqual(report.finalResult, expected)
      XCTAssertEqual(report.attempts.count, 1)
      XCTAssertFalse(report.didAttemptFallback)
      XCTAssertEqual(script.invocationCount, 1)
      XCTAssertTrue(script.sources.first?.contains("NotificationCenter") == true)
      let recovered = await recovery.called
      let errorNumber = await recovery.appleScriptErrorNumber
      XCTAssertEqual(recovered, expectedRecovery != nil)
      XCTAssertEqual(errorNumber, expectedRecovery)
    }
  }

  func testAutomationDeniedTriggersCallback() async throws {
    let recorder = AutomationDeniedRecorder()
    let launcher = TestSystemEventsLauncher(result: false)
    let denied = Int(errAEEventNotPermitted)
    let dependencies = makeActionExecutorDependencies(
      appleScriptExecutor: TestAppleScriptExecutor(
        result: .failure(.init(appleScriptErrorNumber: denied))),
      systemEventsLauncher: launcher
    )
    let executor = ActionExecutor(
      configuration: ActionExecutorConfiguration(
        permissions: .init(
          ensureAutomation: { true },
          onAutomationDenied: { appleScriptErrorNumber in
            await recorder.record(appleScriptErrorNumber: appleScriptErrorNumber)
          })
      ),
      dependencies: dependencies
    )

    let plan = ActionPlan(steps: [
      .init(
        method: .appleScript(
          source: "tell app", launchesSystemEvents: false, usesAccessibility: false))
    ])
    let outcome = try await executor.execute(plan: plan)

    guard case .failure(let error) = outcome.finalResult else {
      return XCTFail("Expected failure")
    }
    XCTAssertEqual(error.code, ActionErrorCode.permissionDenied)
    XCTAssertEqual(error.permission, ActionPermission.automation)
    let recorded = await recorder.appleScriptErrorNumber
    let launchCount = await launcher.invocationCount
    XCTAssertEqual(recorded, denied)
    XCTAssertEqual(launchCount, 0)
  }

  func testAutomationDeniedDoesNotTriggerWhenLastErrorIsAccessibility() async throws {
    let recorder = AutomationDeniedRecorder()
    let denied = Int(errAEEventNotPermitted)
    let dependencies = makeActionExecutorDependencies(
      appleScriptExecutor: TestAppleScriptExecutor(
        result: .failure(.init(appleScriptErrorNumber: denied)))
    )
    let executor = ActionExecutor(
      configuration: ActionExecutorConfiguration(
        permissions: .init(
          ensureAccessibility: { false },
          ensureAutomation: { true },
          onAutomationDenied: { appleScriptErrorNumber in
            await recorder.record(appleScriptErrorNumber: appleScriptErrorNumber)
          })
      ),
      dependencies: dependencies
    )

    let plan = ActionPlan(steps: [
      .init(
        method: .appleScript(
          source: "tell app", launchesSystemEvents: false, usesAccessibility: false)),
      .init(method: .keyEventFromKeyboardShortcut("cmd+a")),
    ])

    let outcome = try await executor.execute(plan: plan)
    guard case .failure(let error) = outcome.finalResult else {
      return XCTFail("Expected failure")
    }
    XCTAssertEqual(error.code, ActionErrorCode.permissionDenied)
    XCTAssertEqual(error.permission, ActionPermission.accessibility)
    let recorded = await recorder.appleScriptErrorNumber
    XCTAssertNil(recorded)
  }

  func testToggleAppearancePreparesSystemEventsBeforeCheckingAutomation() async throws {
    let launcher = TestSystemEventsLauncher()
    let appleScriptExecutor = RecordingAppleScriptExecutor()
    let dependencies = makeActionExecutorDependencies(
      appleScriptExecutor: appleScriptExecutor,
      systemEventsLauncher: launcher
    )
    let executor = ActionExecutor(
      configuration: ActionExecutorConfiguration(
        permissions: .init(
          ensureAutomation: {
            // Like the macOS consent API, the hook cannot succeed before its target runs.
            let prepared = await launcher.invocationCount == 1
            return prepared && appleScriptExecutor.invocationCount == 0
          }
        )
      ),
      dependencies: dependencies
    )

    let outcome = try await executor.execute(.toggleAppearance)

    XCTAssertEqual(outcome.finalResult, ActionResult.success)
    let count = await launcher.invocationCount
    XCTAssertEqual(count, 1)
    XCTAssertEqual(appleScriptExecutor.invocationCount, 1)
    XCTAssertTrue(appleScriptExecutor.sources.first?.contains("appearance preferences") == true)
  }

  func testAccessibilityCheckerFailureDoesNotLaunchSystemEvents() async throws {
    let launcher = TestSystemEventsLauncher()
    let appleScriptExecutor = RecordingAppleScriptExecutor()
    let automationChecks = InvocationRecorder()
    let dependencies = makeActionExecutorDependencies(
      appleScriptExecutor: appleScriptExecutor,
      systemEventsLauncher: launcher
    )
    let executor = ActionExecutor(
      configuration: ActionExecutorConfiguration(
        permissions: .init(
          ensureAccessibility: { false },
          ensureAutomation: {
            automationChecks.record()
            return true
          }
        )
      ),
      dependencies: dependencies
    )

    let plan = ActionPlan(steps: [
      .init(
        method: .appleScript(
          source: "tell app", launchesSystemEvents: true, usesAccessibility: true))
    ])
    let outcome = try await executor.execute(plan: plan)

    XCTAssertEqual(outcome.finalResult, .failure(.permissionDenied(.accessibility)))
    let count = await launcher.invocationCount
    XCTAssertEqual(count, 0)
    XCTAssertEqual(automationChecks.invocationCount, 0)
    XCTAssertEqual(appleScriptExecutor.invocationCount, 0)
  }

  func testAutomationCheckerFailureDoesNotExecuteScriptAfterPreparation() async throws {
    let logs = LogRecorder()
    let launcher = TestSystemEventsLauncher()
    let appleScriptExecutor = RecordingAppleScriptExecutor()
    let dependencies = makeActionExecutorDependencies(
      appleScriptExecutor: appleScriptExecutor,
      systemEventsLauncher: launcher
    )
    let executor = ActionExecutor(
      configuration: ActionExecutorConfiguration(
        permissions: .init(ensureAutomation: { false }),
        log: { level, message in logs.record(level, message) }
      ),
      dependencies: dependencies
    )

    let plan = ActionPlan(steps: [
      .init(
        method: .appleScript(
          source: "tell app", launchesSystemEvents: true, usesAccessibility: false))
    ])
    let outcome = try await executor.execute(plan: plan)

    XCTAssertEqual(outcome.finalResult, .failure(.permissionDenied(.automation)))
    let count = await launcher.invocationCount
    XCTAssertEqual(count, 1)
    XCTAssertEqual(appleScriptExecutor.invocationCount, 0)
    XCTAssertTrue(logs.contains(level: .warning, message: "Permission denied: automation"))
  }

  func testSystemEventsLaunchFailureReturnsInternalErrorBeforeAppleScriptExecution() async throws {
    let launcher = TestSystemEventsLauncher(result: false)
    let appleScriptExecutor = RecordingAppleScriptExecutor()
    let automationChecks = InvocationRecorder()
    let dependencies = makeActionExecutorDependencies(
      appleScriptExecutor: appleScriptExecutor,
      systemEventsLauncher: launcher
    )
    let logs = LogRecorder()
    let executor = ActionExecutor(
      configuration: ActionExecutorConfiguration(
        permissions: .init(
          ensureAccessibility: { true },
          ensureAutomation: {
            automationChecks.record()
            return true
          }
        ),
        log: { level, message in logs.record(level, message) }
      ),
      dependencies: dependencies
    )

    let plan = ActionPlan(steps: [
      .init(
        method: .appleScript(
          source: "tell app", launchesSystemEvents: true, usesAccessibility: false))
    ])
    let outcome = try await executor.execute(plan: plan)

    guard case .failure(let error) = outcome.finalResult else {
      return XCTFail("Expected failure")
    }
    XCTAssertEqual(error.code, ActionErrorCode.internalError)
    XCTAssertTrue(error.diagnosticMessage.contains("System Events is not running"))
    XCTAssertTrue(logs.contains(level: .error, message: "System Events is not running"))
    let count = await launcher.invocationCount
    XCTAssertEqual(count, 1)
    XCTAssertEqual(automationChecks.invocationCount, 0)
    XCTAssertEqual(appleScriptExecutor.invocationCount, 0)
  }

  func testCancellationDuringSystemEventsPreparationDoesNotCheckAutomationOrSendScript() async {
    let automationChecks = InvocationRecorder()
    let logs = InvocationRecorder()
    let appleScriptExecutor = RecordingAppleScriptExecutor()
    let executor = ActionExecutor(
      configuration: .init(
        permissions: .init(ensureAutomation: {
          automationChecks.record()
          return true
        }),
        log: { _, _ in logs.record() }),
      dependencies: makeActionExecutorDependencies(
        appleScriptExecutor: appleScriptExecutor,
        systemEventsLauncher: CancellingSystemEventsLauncher()))
    let task = Task { try await executor.execute(.toggleAppearance) }

    do {
      _ = try await task.value
      XCTFail("Cancellation must stop before checking Automation")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    XCTAssertEqual(automationChecks.invocationCount, 0)
    XCTAssertEqual(appleScriptExecutor.invocationCount, 0)
    XCTAssertEqual(logs.invocationCount, 0)
  }

  func testAppleScriptProcessNotFoundMapsToAppleScriptFailed() async throws {
    let dependencies = makeActionExecutorDependencies(
      appleScriptExecutor: TestAppleScriptExecutor(
        result: .failure(.init(appleScriptErrorNumber: -600)))
    )
    let executor = ActionExecutor(
      configuration: ActionExecutorConfiguration(
        permissions: .init(ensureAutomation: { true })
      ),
      dependencies: dependencies
    )
    let plan = ActionPlan(steps: [
      .init(
        method: .appleScript(
          source: "tell app", launchesSystemEvents: false, usesAccessibility: false))
    ])

    let outcome = try await executor.execute(plan: plan)
    guard case .failure(let error) = outcome.finalResult else {
      return XCTFail("Expected failure")
    }
    XCTAssertEqual(error.code, .appleScriptFailed)
    XCTAssertNil(error.permission)
    XCTAssertEqual(error.appleScriptErrorNumber, -600)
  }

  func testAppleScriptEventNotPermittedMapsToPermissionDenied() async throws {
    let logs = LogRecorder()
    let denied = Int(errAEEventNotPermitted)
    let dependencies = makeActionExecutorDependencies(
      appleScriptExecutor: TestAppleScriptExecutor(
        result: .failure(.init(appleScriptErrorNumber: denied)))
    )
    let executor = ActionExecutor(
      configuration: ActionExecutorConfiguration(
        permissions: .init(ensureAutomation: { true }),
        log: { level, message in logs.record(level, message) }
      ),
      dependencies: dependencies
    )
    let plan = ActionPlan(steps: [
      .init(
        method: .appleScript(
          source: "tell app", launchesSystemEvents: false, usesAccessibility: false))
    ])

    let outcome = try await executor.execute(plan: plan)
    guard case .failure(let error) = outcome.finalResult else {
      return XCTFail("Expected failure")
    }
    XCTAssertEqual(error.code, .permissionDenied)
    XCTAssertEqual(error.permission, .automation)
    XCTAssertEqual(error.appleScriptErrorNumber, denied)
    XCTAssertTrue(
      logs.contains(
        level: .error,
        message: "Permission denied: automation (AppleScript error number \(denied))"
      )
    )
  }

  func testAppleScriptErrorMapsToAppleScriptFailed() async throws {
    let dependencies = makeActionExecutorDependencies(
      appleScriptExecutor: TestAppleScriptExecutor(
        result: .failure(.init(appleScriptErrorNumber: 42)))
    )
    let executor = ActionExecutor(
      configuration: ActionExecutorConfiguration(
        permissions: .init(ensureAutomation: { true })
      ),
      dependencies: dependencies
    )
    let plan = ActionPlan(steps: [
      .init(
        method: .appleScript(
          source: "tell app", launchesSystemEvents: false, usesAccessibility: false))
    ])

    let outcome = try await executor.execute(plan: plan)
    guard case .failure(let error) = outcome.finalResult else {
      return XCTFail("Expected failure")
    }
    XCTAssertEqual(error.code, .appleScriptFailed)
    XCTAssertEqual(error.appleScriptErrorNumber, 42)
    XCTAssertFalse(error.diagnosticMessage.contains("bad"))
    XCTAssertTrue(error.diagnosticMessage.contains("42"))
  }

  func testAppleScriptErrorUsesFailureMessage() async throws {
    let logs = LogRecorder()
    let dependencies = makeActionExecutorDependencies(
      appleScriptExecutor: TestAppleScriptExecutor(
        result: .failure(
          .init(
            appleScriptErrorNumber: 42,
            message: "The variable bad is not defined."
          )
        )
      )
    )
    let executor = ActionExecutor(
      configuration: ActionExecutorConfiguration(
        permissions: .init(ensureAutomation: { true }),
        log: { level, message in logs.record(level, message) }
      ),
      dependencies: dependencies
    )
    let plan = ActionPlan(steps: [
      .init(
        method: .appleScript(
          source: "tell app", launchesSystemEvents: false, usesAccessibility: false))
    ])

    let outcome = try await executor.execute(plan: plan)
    guard case .failure(let error) = outcome.finalResult else {
      return XCTFail("Expected failure")
    }
    XCTAssertEqual(error.code, .appleScriptFailed)
    XCTAssertEqual(error.appleScriptErrorNumber, 42)
    XCTAssertTrue(error.diagnosticMessage.contains("The variable bad is not defined."))
    XCTAssertTrue(error.diagnosticMessage.contains("42"))
    XCTAssertTrue(
      logs.contains(
        level: .error,
        message: "The variable bad is not defined. (AppleScript error number 42)"
      )
    )
  }

  func testAppleScriptErrorUsesFailureMessageWithoutNumber() async throws {
    let logs = LogRecorder()
    let dependencies = makeActionExecutorDependencies(
      appleScriptExecutor: TestAppleScriptExecutor(
        result: .failure(
          .init(
            appleScriptErrorNumber: nil,
            message: "The variable bad is not defined."
          )
        )
      )
    )
    let executor = ActionExecutor(
      configuration: ActionExecutorConfiguration(
        permissions: .init(ensureAutomation: { true }),
        log: { level, message in logs.record(level, message) }
      ),
      dependencies: dependencies
    )
    let plan = ActionPlan(steps: [
      .init(
        method: .appleScript(
          source: "tell app", launchesSystemEvents: false, usesAccessibility: false))
    ])

    let outcome = try await executor.execute(plan: plan)
    guard case .failure(let error) = outcome.finalResult else {
      return XCTFail("Expected failure")
    }
    XCTAssertEqual(error.code, .appleScriptFailed)
    XCTAssertNil(error.appleScriptErrorNumber)
    XCTAssertEqual(error.diagnosticMessage, "The variable bad is not defined.")
    XCTAssertTrue(logs.contains(level: .error, message: "The variable bad is not defined."))
  }

  func testAppleScriptErrorWithoutNumberMapsToAppleScriptFailed() async throws {
    let dependencies = makeActionExecutorDependencies(
      appleScriptExecutor: TestAppleScriptExecutor(
        result: .failure(.init(appleScriptErrorNumber: nil)))
    )
    let executor = ActionExecutor(
      configuration: ActionExecutorConfiguration(
        permissions: .init(ensureAutomation: { true })
      ),
      dependencies: dependencies
    )
    let plan = ActionPlan(steps: [
      .init(
        method: .appleScript(
          source: "tell app", launchesSystemEvents: false, usesAccessibility: false))
    ])

    let outcome = try await executor.execute(plan: plan)
    guard case .failure(let error) = outcome.finalResult else {
      return XCTFail("Expected failure")
    }
    XCTAssertEqual(error.code, .appleScriptFailed)
    XCTAssertNil(error.appleScriptErrorNumber)
    XCTAssertEqual(error.diagnosticMessage, "AppleScript execution failed")
  }

  func testAppleScriptErrorIgnoresBlankFailureMessage() async throws {
    let logs = LogRecorder()
    let dependencies = makeActionExecutorDependencies(
      appleScriptExecutor: TestAppleScriptExecutor(
        result: .failure(
          .init(
            appleScriptErrorNumber: 42,
            message: " \n "
          )
        )
      )
    )
    let executor = ActionExecutor(
      configuration: ActionExecutorConfiguration(
        permissions: .init(ensureAutomation: { true }),
        log: { level, message in logs.record(level, message) }
      ),
      dependencies: dependencies
    )
    let plan = ActionPlan(steps: [
      .init(
        method: .appleScript(
          source: "tell app", launchesSystemEvents: false, usesAccessibility: false))
    ])

    let outcome = try await executor.execute(plan: plan)
    guard case .failure(let error) = outcome.finalResult else {
      return XCTFail("Expected failure")
    }
    XCTAssertEqual(error.code, .appleScriptFailed)
    XCTAssertEqual(error.appleScriptErrorNumber, 42)
    XCTAssertEqual(
      error.diagnosticMessage,
      "AppleScript execution failed with AppleScript error number 42"
    )
    XCTAssertTrue(
      logs.contains(
        level: .error,
        message: "AppleScript execution failed with AppleScript error number 42"
      )
    )
  }

  func testAppleScriptReturnsAutomationPermissionDeniedWhenCheckerFails() async throws {
    let recorder = AutomationDeniedRecorder()
    let appleScriptExecutor = RecordingAppleScriptExecutor()
    let executor = ActionExecutor(
      configuration: ActionExecutorConfiguration(
        permissions: .init(
          ensureAutomation: { false },
          onAutomationDenied: { appleScriptErrorNumber in
            await recorder.record(appleScriptErrorNumber: appleScriptErrorNumber)
          }
        )
      ),
      dependencies: makeActionExecutorDependencies(appleScriptExecutor: appleScriptExecutor)
    )

    let outcome = try await executor.execute(.toggleAppearance)
    XCTAssertEqual(outcome.finalResult, .failure(.permissionDenied(.automation)))
    XCTAssertEqual(outcome.attempts.count, 1)
    XCTAssertEqual(outcome.attempts.first?.result, .failure(.permissionDenied(.automation)))
    XCTAssertEqual(appleScriptExecutor.invocationCount, 0)
    let wasCalled = await recorder.called
    XCTAssertTrue(wasCalled)
  }
}

private struct CancellingSystemEventsLauncher: SystemEventsLaunching {
  func ensureRunning() async -> Bool {
    withUnsafeCurrentTask { $0?.cancel() }
    return false
  }
}

final class RecordingAppleScriptExecutor: AppleScriptExecuting, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  private var recordedSources: [String] = []
  private let result: Result<Void, AppleScriptExecutionFailure>

  init(result: Result<Void, AppleScriptExecutionFailure> = .success(())) {
    self.result = result
  }

  func execute(source: String) async -> Result<Void, AppleScriptExecutionFailure> {
    lock.withLock {
      count += 1
      recordedSources.append(source)
    }
    return result
  }

  var invocationCount: Int {
    lock.withLock {
      count
    }
  }

  var sources: [String] {
    lock.withLock {
      recordedSources
    }
  }
}
