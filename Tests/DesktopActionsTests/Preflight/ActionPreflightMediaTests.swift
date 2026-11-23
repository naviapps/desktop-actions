import DesktopActions
import XCTest

final class ActionPreflightMediaTests: XCTestCase {
  func testMediaPlanProjectsSystemKeyAndPermissions() {
    let plan = ActionPreflight.plan(for: .mediaPlayPause)
    XCTAssertEqual(plan.steps.map(\.method), [.systemKey(16)])
    XCTAssertEqual(plan.permissionRequirements, .init(primary: [.accessibility], fallback: []))
  }
}
