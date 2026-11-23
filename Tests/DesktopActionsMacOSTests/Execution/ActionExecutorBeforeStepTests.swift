import DesktopActions
import DesktopActionsMacOS
import Foundation
import XCTest

final class ActionExecutorBeforeStepTests: XCTestCase {
  func testBeforeStepRejectsBeforeAccessibilityOrAutomationPreparation() async {
    let accessibility = InvocationRecorder()
    let automation = InvocationRecorder()
    let systemEvents = TestSystemEventsLauncher()
    let scriptCalls = InvocationRecorder()
    let keys = TestKeyEventPoster()
    let executor = ActionExecutor(
      configuration: .init(
        permissions: .init(
          ensureAccessibility: {
            accessibility.record()
            return true
          },
          ensureAutomation: {
            automation.record()
            return true
          })),
      dependencies: makeActionExecutorDependencies(
        keyEventPoster: keys,
        appleScriptExecutor: StepGuardScript {
          scriptCalls.record()
          return .success(())
        },
        systemEventsLauncher: systemEvents))

    for action in [ActionRequest.copy, .showDesktop] {
      await assertRejected { try await executor.execute(action, beforeStep: { false }) }
    }

    let systemEventsCalls = await systemEvents.invocationCount
    XCTAssertEqual(accessibility.invocationCount, 0)
    XCTAssertEqual(automation.invocationCount, 0)
    XCTAssertEqual(systemEventsCalls, 0)
    XCTAssertEqual(scriptCalls.invocationCount, 0)
    XCTAssertTrue(keys.postedEvents.isEmpty)
  }

  func testBeforeStepRejectsAfterSystemEventsStartsWithoutCheckingAutomation() async {
    let entered = expectation(description: "System Events starter is pending")
    let startup = SuspendedStepPermission(entered: entered, granted: true)
    let permit = StepPermit()
    let accessibility = InvocationRecorder()
    let automation = InvocationRecorder()
    let scriptCalls = InvocationRecorder()
    let keys = TestKeyEventPoster()
    let executor = ActionExecutor(
      configuration: .init(
        permissions: .init(
          ensureAccessibility: {
            accessibility.record()
            return true
          },
          ensureAutomation: {
            automation.record()
            return true
          })),
      dependencies: makeActionExecutorDependencies(
        keyEventPoster: keys,
        appleScriptExecutor: StepGuardScript {
          scriptCalls.record()
          return .success(())
        },
        systemEventsLauncher: StepGuardSystemEventsLauncher(startup: startup)))
    let task = Task {
      try await executor.execute(.showDesktop, beforeStep: { await permit.check() })
    }

    await fulfillment(of: [entered], timeout: 2)
    await permit.revoke()
    await startup.resume()
    await assertRejected { try await task.value }

    XCTAssertEqual(accessibility.invocationCount, 1, "The fallback must not check permission")
    XCTAssertEqual(automation.invocationCount, 0)
    XCTAssertEqual(scriptCalls.invocationCount, 0)
    XCTAssertTrue(keys.postedEvents.isEmpty)
  }

  func testBeforeStepRejectsAfterAwaitedPermissionWithoutRunningActionOrFallback() async {
    for granted in [true, false] {
      let entered = expectation(description: "Automation prerequisite is pending")
      let permission = SuspendedStepPermission(entered: entered, granted: granted)
      let permit = StepPermit()
      let accessibility = InvocationRecorder()
      let scriptCalls = InvocationRecorder()
      let keys = TestKeyEventPoster()
      let executor = ActionExecutor(
        configuration: .init(
          permissions: .init(
            ensureAccessibility: {
              accessibility.record()
              return true
            },
            ensureAutomation: { await permission.wait() })),
        dependencies: makeActionExecutorDependencies(
          keyEventPoster: keys,
          appleScriptExecutor: StepGuardScript {
            scriptCalls.record()
            return .success(())
          }))
      let task = Task {
        try await executor.execute(.showDesktop, beforeStep: { await permit.check() })
      }

      await fulfillment(of: [entered], timeout: 2)
      let checksBeforePermission = await permit.checks
      XCTAssertGreaterThan(checksBeforePermission, 0)
      await permit.revoke()
      await permission.resume()

      await assertRejected { try await task.value }
      let checks = await permit.checks
      XCTAssertEqual(checks, checksBeforePermission + 1)
      XCTAssertEqual(accessibility.invocationCount, 1, "The fallback must not check permission")
      XCTAssertEqual(scriptCalls.invocationCount, 0)
      XCTAssertTrue(keys.postedEvents.isEmpty)
    }
  }

  func testBeforeStepRejectsPermissionlessDispatchAndLegacyStillOpens() async throws {
    let workspace = TestWorkspace()
    let guardCalls = InvocationRecorder()
    let executor = ActionExecutor(
      configuration: .init(
        permissions: .init(ensureAccessibility: {
          XCTFail("Opening a URL must not request Accessibility")
          return false
        })),
      dependencies: makeActionExecutorDependencies(workspace: workspace))
    let value = "https://example.com/"
    let action = ActionRequest.openURL(value)

    await assertRejected {
      try await executor.execute(
        action,
        beforeStep: {
          guardCalls.record()
          return false
        })
    }

    let beforeLegacy = await workspace.lastOpenedURL
    XCTAssertNil(beforeLegacy)
    XCTAssertEqual(guardCalls.invocationCount, 1)
    let report = try await executor.execute(action)
    XCTAssertEqual(report.finalResult, .success)
    let afterLegacy = await workspace.lastOpenedURL
    XCTAssertEqual(afterLegacy, URL(string: value))
    XCTAssertEqual(guardCalls.invocationCount, 1)
  }

  func testBeforeStepRechecksFallbackAfterPermittedPrimaryFails() async {
    let permit = StepPermit()
    let accessibility = InvocationRecorder()
    let scriptCalls = InvocationRecorder()
    let keys = TestKeyEventPoster()
    let executor = ActionExecutor(
      configuration: .init(
        permissions: .init(
          ensureAccessibility: {
            accessibility.record()
            return true
          },
          ensureAutomation: { true })),
      dependencies: makeActionExecutorDependencies(
        keyEventPoster: keys,
        appleScriptExecutor: StepGuardScript {
          scriptCalls.record()
          await permit.revoke()
          return .failure(.init(message: "Fixture failure"))
        }))

    await assertRejected {
      try await executor.execute(.showDesktop, beforeStep: { await permit.check() })
    }

    XCTAssertEqual(accessibility.invocationCount, 1, "The fallback must not check permission")
    XCTAssertEqual(scriptCalls.invocationCount, 1)
    XCTAssertTrue(keys.postedEvents.isEmpty)
  }

  func testCancellationInsideBeforeStepPreventsDispatchEvenWhenAllowed() async {
    let workspace = TestWorkspace()
    let executor = ActionExecutor(
      dependencies: makeActionExecutorDependencies(workspace: workspace))
    let task = Task {
      try await executor.execute(
        .openURL("https://example.com"),
        beforeStep: {
          withUnsafeCurrentTask { $0?.cancel() }
          return true
        })
    }

    await assertRejected { try await task.value }
    let opened = await workspace.lastOpenedURL
    XCTAssertNil(opened)
  }

  private func assertRejected(_ operation: () async throws -> ActionExecutionReport) async {
    do {
      _ = try await operation()
      XCTFail("The execution must throw CancellationError")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
  }
}

private actor StepPermit {
  private var valid = true
  private(set) var checks = 0

  func revoke() { valid = false }

  func check() -> Bool {
    checks += 1
    return valid
  }
}

private actor SuspendedStepPermission {
  let entered: XCTestExpectation
  let granted: Bool
  private var continuation: CheckedContinuation<Void, Never>?
  private var released = false

  init(entered: XCTestExpectation, granted: Bool) {
    self.entered = entered
    self.granted = granted
  }

  func wait() async -> Bool {
    entered.fulfill()
    if !released {
      await withCheckedContinuation { continuation = $0 }
    }
    return granted
  }

  func resume() {
    released = true
    continuation?.resume()
    continuation = nil
  }
}

private struct StepGuardScript: AppleScriptExecuting {
  let operation: @Sendable () async -> Result<Void, AppleScriptExecutionFailure>

  func execute(source _: String) async -> Result<Void, AppleScriptExecutionFailure> {
    await operation()
  }
}

private struct StepGuardSystemEventsLauncher: SystemEventsLaunching {
  let startup: SuspendedStepPermission

  func ensureRunning() async -> Bool {
    await startup.wait()
  }
}
