import DesktopActions
import XCTest

final class ActionPreflightSystemTests: XCTestCase {
  func testSystemPlanProjectsFallbackMethodsAndPermissionSets() throws {
    let plan = ActionPreflight.plan(for: .showDesktop)
    XCTAssertEqual(plan.steps.count, 2)
    XCTAssertEqual(
      plan.permissionRequirements,
      .init(primary: [.accessibility, .automation], fallback: [.accessibility])
    )

    let primary = try XCTUnwrap(plan.steps.first)
    guard
      case .appleScript(
        source: let source,
        launchesSystemEvents: let launchesSystemEvents,
        usesAccessibility: let usesAccessibility
      ) = primary.method
    else {
      return XCTFail("Expected AppleScript primary")
    }
    XCTAssertFalse(primary.isFallback)
    XCTAssertTrue(launchesSystemEvents)
    XCTAssertTrue(usesAccessibility)
    XCTAssertTrue(source.contains("System Events"))
    XCTAssertEqual(primary.requiredPermissions, [.accessibility, .automation])
    assertKeyEventStep(
      plan.steps.dropFirst().first,
      matches: .init(action: .showDesktop, virtualKeyCode: 103, modifiers: [.function]),
      isFallback: true,
      requiredPermissions: [.accessibility]
    )
  }

  func testCapturePlanProjectsOrderedArgumentsAndScreenRecordingPermission() throws {
    let plan = ActionPreflight.plan(for: .captureScreenFull)
    let step = try XCTUnwrap(plan.steps.first)
    XCTAssertEqual(step.method, .screenCapture(arguments: ["-p", "-x"]))
    XCTAssertEqual(step.requiredPermissions, [.screenRecording])
    XCTAssertEqual(
      plan.permissionRequirements, .init(primary: [.screenRecording], fallback: [])
    )
  }
}
