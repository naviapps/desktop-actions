import DesktopActions
import XCTest

final class ActionPreflightKeyboardTests: XCTestCase {
  func testPublicShortcutValidationProjectsNativeResult() {
    XCTAssertTrue(ActionPreflight.isValidKeyboardShortcut("⌘K"))
    XCTAssertFalse(ActionPreflight.isValidKeyboardShortcut("cmd++c"))
  }

  func testKeyboardPlanProjectsNormalizedShortcutAndPermissions() {
    let plan = ActionPreflight.plan(for: .keyboardShortcut("  cmd+shift+p  "))
    XCTAssertEqual(plan.steps.count, 1)
    XCTAssertEqual(plan.steps.first?.requiredPermissions, [.accessibility])
    XCTAssertEqual(plan.permissionRequirements, .init(primary: [.accessibility], fallback: []))

    guard case .keyEventFromKeyboardShortcut(let value) = plan.steps.first?.method else {
      return XCTFail("Expected keyboard shortcut step")
    }

    XCTAssertEqual(value, "cmd+shift+p")
  }
}
