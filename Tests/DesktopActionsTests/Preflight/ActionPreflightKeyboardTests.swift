import DesktopActions
import XCTest

final class ActionPreflightKeyboardTests: XCTestCase {
  func testPublicShortcutValidationAcceptsExecutorVocabulary() {
    for value in ["⌘K", " cmd+shift+? ", "fn-forward-delete", "cmd-page-down", "shift+plus", "f20"]
    {
      XCTAssertTrue(ActionPreflight.isValidKeyboardShortcut(value), value)
    }
  }

  func testPublicShortcutValidationRejectsMalformedInput() {
    for value in ["", "cmd", "⌘cmd+k", "cmd++c", "cmd-page--down", "f21", "cmd unknown"] {
      XCTAssertFalse(ActionPreflight.isValidKeyboardShortcut(value), value)
    }
  }

  func testKeyboardShortcutUsesKeyboardPlan() {
    let plan = ActionPreflight.plan(for: .keyboardShortcut("cmd+shift+p"))
    XCTAssertEqual(plan.steps.count, 1)
    XCTAssertEqual(plan.steps.first?.requiredPermissions, [.accessibility])
    XCTAssertEqual(plan.permissionRequirements, .init(primary: [.accessibility], fallback: []))

    guard case .keyEventFromKeyboardShortcut(let value) = plan.steps.first?.method else {
      return XCTFail("Expected keyboard shortcut step")
    }

    XCTAssertEqual(value, "cmd+shift+p")
  }

  func testKeyboardPlanReceivesRustNormalizedShortcut() {
    let plan = ActionPreflight.plan(for: .keyboardShortcut("  cmd+shift+p  "))

    guard case .keyEventFromKeyboardShortcut(let value) = plan.steps.first?.method else {
      return XCTFail("Expected keyboard shortcut step")
    }

    XCTAssertEqual(value, "cmd+shift+p")
  }
}
