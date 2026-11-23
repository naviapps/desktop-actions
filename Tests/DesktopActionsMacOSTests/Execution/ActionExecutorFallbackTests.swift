import ApplicationServices
import DesktopActions
import DesktopActionsMacOS
import XCTest

@MainActor
final class ActionExecutorFallbackTests: XCTestCase {
  func testRejectsWindowsPlanBeforePermissionPreparationOrNativeEffects() async throws {
    let checks = InvocationRecorder()
    let keys = TestKeyEventPoster()
    let executor = ActionExecutor(
      configuration: .init(
        permissions: .init(ensureAccessibility: {
          checks.record()
          return true
        })),
      dependencies: makeActionExecutorDependencies(keyEventPoster: keys))

    let outcome = try await executor.execute(plan: ActionRequest.copy.plan(for: .windows))

    guard case .failure(let error) = outcome.finalResult else {
      return XCTFail("Expected rejection of a Windows virtual key plan.")
    }
    XCTAssertEqual(error.code, .unsupportedAction)
    XCTAssertEqual(checks.invocationCount, 0)
    XCTAssertTrue(keys.postedEvents.isEmpty)
  }

  func testEmptyPlanRecordsInternalErrorAttempt() async throws {
    let recorder = AutomationDeniedRecorder()
    let executor = ActionExecutor(
      configuration: .init(
        permissions: .init(
          onAutomationDenied: { appleScriptErrorNumber in
            await recorder.record(appleScriptErrorNumber: appleScriptErrorNumber)
          })
      ),
      dependencies: makeActionExecutorDependencies()
    )

    let outcome = try await executor.execute(plan: ActionPlan(steps: []))

    XCTAssertEqual(outcome.attempts.count, 1)
    XCTAssertEqual(
      outcome.finalResult,
      .failure(.internalError("No execution attempts were recorded"))
    )
    XCTAssertEqual(outcome.attempts.first?.result, outcome.finalResult)
    XCTAssertEqual(outcome.attempts.first?.requiredPermissions, [])
    XCTAssertFalse(outcome.attempts.first?.isFallback ?? true)
    let wasCalled = await recorder.called
    XCTAssertFalse(wasCalled)
  }

  func testShowDesktopWhenAutomationDeniedUsesKeyStrokeAndDoesNotCallOnAutomationDenied()
    async throws
  {
    let recorder = AutomationDeniedRecorder()

    let dependencies = makeActionExecutorDependencies(
      frontmostApplicationController: TestFrontmostApplicationController(
        hideResult: .noFrontmostApplication),
      appleScriptExecutor: TestAppleScriptExecutor(
        result: .failure(.init(appleScriptErrorNumber: Int(errAEEventNotPermitted)))
      )
    )

    let executor = ActionExecutor(
      configuration: .init(
        permissions: .init(
          ensureAccessibility: { true },
          ensureAutomation: { true },
          onAutomationDenied: { appleScriptErrorNumber in
            await recorder.record(appleScriptErrorNumber: appleScriptErrorNumber)
          })
      ),
      dependencies: dependencies
    )

    let outcome = try await executor.execute(.showDesktop)
    XCTAssertEqual(outcome.finalResult, .success)
    XCTAssertTrue(outcome.didAttemptFallback)
    XCTAssertEqual(outcome.attempts.count, 2)
    XCTAssertEqual(outcome.attempts.last?.isFallback, true)
    guard case .failure(let error)? = outcome.attempts.first?.result else {
      return XCTFail(
        "Expected failure for first attempt, got: \(String(describing: outcome.attempts.first?.result))"
      )
    }
    XCTAssertEqual(error.code, .permissionDenied)
    XCTAssertEqual(error.permission, .automation)
    XCTAssertNotNil(error.appleScriptErrorNumber)
    let wasCalled = await recorder.called
    XCTAssertFalse(wasCalled)
  }

  func testShowDesktopWhenSystemEventsCannotStartStillUsesKeyStroke() async throws {
    let launcher = TestSystemEventsLauncher(result: false)
    let automationChecks = InvocationRecorder()
    let keys = TestKeyEventPoster()
    let executor = ActionExecutor(
      configuration: .init(
        permissions: .init(
          ensureAccessibility: { true },
          ensureAutomation: {
            automationChecks.record()
            return true
          })),
      dependencies: makeActionExecutorDependencies(
        keyEventPoster: keys, systemEventsLauncher: launcher))

    let outcome = try await executor.execute(.showDesktop)

    XCTAssertEqual(outcome.finalResult, .success)
    XCTAssertTrue(outcome.didAttemptFallback)
    XCTAssertEqual(
      outcome.attempts.first?.result, .failure(.internalError("System Events is not running")))
    XCTAssertEqual(keys.postedEvents.count, 1)
    XCTAssertEqual(automationChecks.invocationCount, 0)
  }

  func testSkippedPrimaryContinuesToFallbackStep() async throws {
    let dependencies = makeActionExecutorDependencies(
      workspace: TestWorkspace(),
      frontmostApplicationController: TestFrontmostApplicationController(
        hideResult: .noFrontmostApplication)
    )

    let executor = ActionExecutor(configuration: .init(), dependencies: dependencies)

    let plan = ActionPlan(steps: [
      .init(method: .hideFrontmostApplication),
      .init(method: .openURL("https://example.com"), isFallback: true),
    ])

    let outcome = try await executor.execute(plan: plan)
    XCTAssertEqual(outcome.finalResult, .success)
    XCTAssertTrue(outcome.didAttemptFallback)
    XCTAssertEqual(outcome.attempts.count, 2)
    XCTAssertEqual(outcome.attempts.first?.result, .skipped(.noFrontmostApplication))
    XCTAssertEqual(outcome.attempts.last?.result, .success)
  }

  func testSuccessfulPrimaryDoesNotAttemptFallbackStep() async throws {
    let dependencies = makeActionExecutorDependencies(workspace: TestWorkspace())
    let executor = ActionExecutor(configuration: .init(), dependencies: dependencies)

    let plan = ActionPlan(steps: [
      .init(method: .openURL("https://example.com")),
      .init(method: .keyEventFromKeyboardShortcut("cmd"), isFallback: true),
    ])

    let outcome = try await executor.execute(plan: plan)
    XCTAssertEqual(outcome.finalResult, .success)
    XCTAssertFalse(outcome.didAttemptFallback)
    XCTAssertEqual(outcome.attempts.count, 1)
    XCTAssertEqual(outcome.attempts.first?.result, .success)
  }

  func testAllStepsSkippedReturnsSkippedResult() async throws {
    let dependencies = makeActionExecutorDependencies(
      workspace: TestWorkspace(),
      frontmostApplicationController: TestFrontmostApplicationController(
        hideResult: .noFrontmostApplication)
    )

    let executor = ActionExecutor(configuration: .init(), dependencies: dependencies)

    let plan = ActionPlan(steps: [
      .init(method: .hideFrontmostApplication)
    ])

    let outcome = try await executor.execute(plan: plan)
    XCTAssertEqual(outcome.finalResult, .skipped(.noFrontmostApplication))
    XCTAssertEqual(outcome.attempts.count, 1)
    XCTAssertEqual(outcome.attempts.first?.result, .skipped(.noFrontmostApplication))
    XCTAssertFalse(outcome.didAttemptFallback)
    XCTAssertNotNil(outcome.attempts.first?.duration)
  }

  func testRepeatedExecutionsDoNotCarryAttemptState() async throws {
    let dependencies = makeActionExecutorDependencies(
      workspace: TestWorkspace(),
      frontmostApplicationController: TestFrontmostApplicationController(
        hideResult: .noFrontmostApplication)
    )
    let executor = ActionExecutor(configuration: .init(), dependencies: dependencies)

    let skipped = try await executor.execute(
      plan: ActionPlan(steps: [
        .init(method: .hideFrontmostApplication)
      ])
    )
    let succeeded = try await executor.execute(
      plan: ActionPlan(steps: [
        .init(method: .openURL("https://example.com"))
      ])
    )

    XCTAssertEqual(skipped.finalResult, .skipped(.noFrontmostApplication))
    XCTAssertEqual(skipped.attempts.count, 1)
    XCTAssertEqual(succeeded.finalResult, .success)
    XCTAssertEqual(succeeded.attempts.count, 1)
    XCTAssertFalse(succeeded.didAttemptFallback)
  }

  func testAutomationDeniedWithNoFallbackCallsOnAutomationDeniedWithErrorNumber() async throws {
    let recorder = AutomationDeniedRecorder()
    let denied = Int(errAEEventNotPermitted)

    let dependencies = makeActionExecutorDependencies(
      workspace: TestWorkspace(),
      frontmostApplicationController: TestFrontmostApplicationController(
        hideResult: .noFrontmostApplication),
      appleScriptExecutor: TestAppleScriptExecutor(
        result: .failure(.init(appleScriptErrorNumber: denied))
      )
    )

    let executor = ActionExecutor(
      configuration: .init(
        permissions: .init(
          ensureAccessibility: { true },
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
          source: "tell application \"System Events\" to keystroke \"a\"",
          launchesSystemEvents: true,
          usesAccessibility: true
        ))
    ])

    let outcome = try await executor.execute(plan: plan)
    guard case .failure(let error) = outcome.finalResult else {
      return XCTFail("Expected failure, got: \(outcome.finalResult)")
    }
    XCTAssertEqual(error.code, .permissionDenied)
    XCTAssertEqual(error.permission, .automation)
    XCTAssertEqual(error.appleScriptErrorNumber, denied)

    let wasCalled = await recorder.called
    XCTAssertTrue(wasCalled)
    let last = await recorder.appleScriptErrorNumber
    XCTAssertEqual(last, denied)
  }

  func testAutomationDeniedCallbackPreservesErrorNumberWhenFallbackFailsDifferently() async throws {
    let recorder = AutomationDeniedRecorder()
    let denied = Int(errAEEventNotPermitted)
    let dependencies = makeActionExecutorDependencies(
      appleScriptExecutor: TestAppleScriptExecutor(
        result: .failure(.init(appleScriptErrorNumber: denied))
      )
    )
    let executor = ActionExecutor(
      configuration: .init(
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
          source: "tell app", launchesSystemEvents: false, usesAccessibility: false)),
      .init(method: .keyEventFromKeyboardShortcut("cmd"), isFallback: true),
    ])

    let outcome = try await executor.execute(plan: plan)
    guard case .failure(let error) = outcome.finalResult else {
      return XCTFail("Expected failure, got: \(outcome.finalResult)")
    }
    XCTAssertEqual(error.code, .invalidInput)
    let wasCalled = await recorder.called
    XCTAssertTrue(wasCalled)
    let recorded = await recorder.appleScriptErrorNumber
    XCTAssertEqual(recorded, denied)
  }

  func testAutomationDeniedCallbackRunsWhenFallbackIsSkipped() async throws {
    let recorder = AutomationDeniedRecorder()
    let denied = Int(errAEEventNotPermitted)
    let dependencies = makeActionExecutorDependencies(
      frontmostApplicationController: TestFrontmostApplicationController(
        hideResult: .noFrontmostApplication),
      appleScriptExecutor: TestAppleScriptExecutor(
        result: .failure(.init(appleScriptErrorNumber: denied))
      )
    )
    let executor = ActionExecutor(
      configuration: .init(
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
          source: "tell app", launchesSystemEvents: false, usesAccessibility: false)),
      .init(method: .hideFrontmostApplication, isFallback: true),
    ])

    let outcome = try await executor.execute(plan: plan)
    XCTAssertEqual(outcome.finalResult, .skipped(.noFrontmostApplication))
    XCTAssertTrue(outcome.didAttemptFallback)
    XCTAssertEqual(outcome.attempts.count, 2)
    let wasCalled = await recorder.called
    XCTAssertTrue(wasCalled)
    let recorded = await recorder.appleScriptErrorNumber
    XCTAssertEqual(recorded, denied)
  }

  func testAutomationDeniedCallbackPreservesEarlierErrorNumberWhenLaterDenialHasNoNumber()
    async throws
  {
    let recorder = AutomationDeniedRecorder()
    let denied = Int(errAEEventNotPermitted)
    var automationCheckCount = 0
    let dependencies = makeActionExecutorDependencies(
      appleScriptExecutor: TestAppleScriptExecutor(
        result: .failure(.init(appleScriptErrorNumber: denied))
      )
    )
    let executor = ActionExecutor(
      configuration: .init(
        permissions: .init(
          ensureAutomation: {
            automationCheckCount += 1
            return automationCheckCount == 1
          },
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
      .init(
        method: .appleScript(
          source: "tell app", launchesSystemEvents: false, usesAccessibility: false),
        isFallback: true
      ),
    ])

    let outcome = try await executor.execute(plan: plan)
    XCTAssertEqual(outcome.finalResult, .failure(.permissionDenied(.automation)))
    let wasCalled = await recorder.called
    XCTAssertTrue(wasCalled)
    let recorded = await recorder.appleScriptErrorNumber
    XCTAssertEqual(recorded, denied)
  }
}
