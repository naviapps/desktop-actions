import ApplicationServices
import DesktopActions
import DesktopActionsMacOS
import XCTest

final class ActionExecutorKeyboardTests: XCTestCase {
  func testMediaAndBrightnessUseSystemKeysWithoutTypingOrdinaryKeys() async throws {
    let poster = TestKeyEventPoster()
    let executor = ActionExecutor(
      configuration: .init(permissions: .init(ensureAccessibility: { true })),
      dependencies: makeActionExecutorDependencies(keyEventPoster: poster))
    for action: ActionRequest in [
      .volumeUp, .volumeDown, .toggleAudioMute, .mediaPlayPause, .mediaNext,
      .mediaPrevious, .brightnessUp, .brightnessDown,
    ] {
      let outcome = try await executor.execute(action)
      XCTAssertEqual(outcome.finalResult, .success)
    }
    XCTAssertEqual(poster.postedSystemKeys, [0, 1, 7, 16, 17, 18, 2, 3])
    XCTAssertTrue(poster.postedEvents.isEmpty)
  }

  func testKeyboardShortcutPostsParsedKeyStroke() async throws {
    let keyEventPoster = TestKeyEventPoster()
    let dependencies = makeActionExecutorDependencies(keyEventPoster: keyEventPoster)
    let executor = ActionExecutor(
      configuration: ActionExecutorConfiguration(
        permissions: .init(ensureAccessibility: { true })
      ),
      dependencies: dependencies
    )
    let plan = ActionPlan(steps: [.init(method: .keyEventFromKeyboardShortcut("cmd shift z"))])

    let outcome = try await executor.execute(plan: plan)
    XCTAssertEqual(outcome.finalResult, .success)
    XCTAssertEqual(keyEventPoster.postedEvents.map(\.virtualKey), [6])
    XCTAssertEqual(keyEventPoster.postedEvents.map(\.flags), [[.maskCommand, .maskShift]])
  }

  func testKeyEventPostsModifierFlags() async throws {
    let keyEventPoster = TestKeyEventPoster()
    let dependencies = makeActionExecutorDependencies(keyEventPoster: keyEventPoster)
    let executor = ActionExecutor(
      configuration: ActionExecutorConfiguration(
        permissions: .init(ensureAccessibility: { true })
      ),
      dependencies: dependencies
    )
    let plan = ActionPlan(
      steps: [
        .init(
          method: .keyEvent(
            virtualKeyCode: 120,
            modifiers: [.command, .shift, .option, .control, .function]
          )
        )
      ]
    )

    let outcome = try await executor.execute(plan: plan)
    XCTAssertEqual(outcome.finalResult, .success)
    XCTAssertEqual(keyEventPoster.postedEvents.map(\.virtualKey), [120])
    XCTAssertEqual(
      keyEventPoster.postedEvents.map(\.flags),
      [[.maskCommand, .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn]]
    )
  }

  func testKeyStrokeReturnsAccessibilityPermissionDeniedWhenCheckerFails() async throws {
    let logs = LogRecorder()
    let keyEventPoster = TestKeyEventPoster()
    let dependencies = makeActionExecutorDependencies(keyEventPoster: keyEventPoster)
    let executor = ActionExecutor(
      configuration: ActionExecutorConfiguration(
        permissions: .init(ensureAccessibility: { false }),
        log: { level, message in logs.record(level, message) }
      ),
      dependencies: dependencies
    )

    let outcome = try await executor.execute(.copy)
    XCTAssertEqual(outcome.finalResult, .failure(.permissionDenied(.accessibility)))
    XCTAssertEqual(outcome.attempts.count, 1)
    XCTAssertEqual(outcome.attempts.first?.result, .failure(.permissionDenied(.accessibility)))
    XCTAssertTrue(keyEventPoster.postedEvents.isEmpty)
    XCTAssertTrue(logs.contains(level: .warning, message: "Permission denied: accessibility"))
  }

  func testKeyboardShortcutInvalidReturnsInvalidInput() async throws {
    let logs = LogRecorder()
    let keyEventPoster = TestKeyEventPoster()
    let accessibilityRecorder = InvocationRecorder()
    let dependencies = makeActionExecutorDependencies(keyEventPoster: keyEventPoster)
    let executor = ActionExecutor(
      configuration: ActionExecutorConfiguration(
        permissions: .init(ensureAccessibility: {
          accessibilityRecorder.record()
          return true
        }),
        log: { level, message in logs.record(level, message) }
      ),
      dependencies: dependencies
    )
    let plan = ActionPlan(steps: [.init(method: .keyEventFromKeyboardShortcut("cmd"))])

    let outcome = try await executor.execute(plan: plan)
    guard case .failure(let error) = outcome.finalResult else {
      return XCTFail("Expected failure")
    }
    XCTAssertEqual(error.code, .invalidInput)
    XCTAssertEqual(error.diagnosticMessage, "Invalid keyboard shortcut for the target platform")
    XCTAssertTrue(
      logs.contains(level: .warning, message: "Invalid keyboard shortcut for the target platform"))
    XCTAssertTrue(keyEventPoster.postedEvents.isEmpty)
    XCTAssertEqual(accessibilityRecorder.invocationCount, 0)
  }

  func testKeyEventFailureReturnsInternalError() async throws {
    let logs = LogRecorder()
    let dependencies = makeActionExecutorDependencies(
      keyEventPoster: TestKeyEventPoster(result: false)
    )
    let executor = ActionExecutor(
      configuration: ActionExecutorConfiguration(
        permissions: .init(ensureAccessibility: { true }),
        log: { level, message in logs.record(level, message) }
      ),
      dependencies: dependencies
    )
    let plan = ActionPlan(steps: [.init(method: .keyEvent(.init(virtualKeyCode: 0)))])

    let outcome = try await executor.execute(plan: plan)
    guard case .failure(let error) = outcome.finalResult else {
      return XCTFail("Expected failure")
    }
    XCTAssertEqual(error.code, .internalError)
    XCTAssertEqual(error.diagnosticMessage, "Failed to post key stroke event")
    XCTAssertTrue(logs.contains(level: .error, message: "Failed to post key stroke event"))
  }
}
