import DesktopActions
import XCTest

final class ActionPreflightPermissionHintTests: XCTestCase {
  func testPermissionsForActionKindsDoNotRequireConstructedActions() {
    XCTAssertEqual(
      ActionPreflight.permissions(forKind: .showDesktop),
      .init(primary: [.accessibility, .automation], fallback: [.accessibility])
    )
  }

  func testPermissionHintsUseActionSpecificReasons() {
    XCTAssertEqual(
      ActionPreflight.permissionHints(for: .copy),
      [.init(permission: .accessibility, reason: .accessibilityKeyEvent)]
    )
    XCTAssertEqual(
      ActionPreflight.permissionHints(forKind: ActionKind.windowPlacement),
      [.init(permission: .accessibility, reason: .accessibilityWindowing)]
    )
    XCTAssertEqual(
      ActionPreflight.permissionHints(forKind: ActionKind.toggleAppearance),
      [.init(permission: .automation, reason: .automationAppleEvents)]
    )
    XCTAssertEqual(
      ActionPreflight.permissionHints(forKind: ActionKind.captureScreenFull),
      [.init(permission: .screenRecording, reason: .screenRecordingCapture)]
    )
    XCTAssertTrue(ActionPreflight.permissionHints(for: .launchApplication("")).isEmpty)
  }

  func testPermissionHintsForActionKindsDoNotRequireConstructedActions() {
    XCTAssertEqual(
      ActionPreflight.permissionHints(forKind: .windowMove),
      [.init(permission: .accessibility, reason: .accessibilityWindowing)]
    )
  }

  func testPermissionHintsUseExecutionPlanOrder() {
    XCTAssertEqual(
      ActionPreflight.permissionHints(forKind: ActionKind.showDesktop),
      [
        .init(permission: .accessibility, reason: .accessibility),
        .init(permission: .automation, reason: .automationAppleEvents),
      ]
    )
  }
}
