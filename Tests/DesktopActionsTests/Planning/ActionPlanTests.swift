import DesktopActions
import XCTest

final class ActionPlanTests: XCTestCase {
  func testPlansKeepDistinctUTF8PathSpellings() {
    let composed = "/tmp/caf\u{00E9}"
    let decomposed = "/tmp/cafe\u{0301}"
    let first = ActionRequest.openFolder(composed).plan(for: .macOS)
    let second = ActionRequest.openFolder(decomposed).plan(for: .macOS)
    guard case .openFolder(let firstPath) = first.steps.first?.method,
      case .openFolder(let secondPath) = second.steps.first?.method
    else {
      return XCTFail("Expected folder instructions")
    }
    XCTAssertTrue(firstPath.utf8.elementsEqual(composed.utf8))
    XCTAssertTrue(secondPath.utf8.elementsEqual(decomposed.utf8))
    XCTAssertNotEqual(first.steps, second.steps)
    let equivalent = ActionRequest.openFolder(composed).plan(for: .macOS)
    XCTAssertEqual(Set([first, second, equivalent]).count, 2)
  }

  func testEmptyPlanHasNoPermissionRequirements() {
    let plan = ActionPlan(steps: [])

    XCTAssertTrue(plan.permissionRequirements.isEmpty)
    XCTAssertEqual(plan.permissionRequirements.primary, [])
    XCTAssertEqual(plan.permissionRequirements.fallback, [])
  }

  func testPermissionRequirementsAggregation() {
    let primaryStep = ActionStep(
      method: .appleScript(
        source: "tell app",
        launchesSystemEvents: true,
        usesAccessibility: true
      ),
      isFallback: false
    )
    let fallbackStep = ActionStep(
      method: .screenCapture(arguments: ["-x"]),
      isFallback: true
    )
    let plan = ActionPlan(steps: [primaryStep, fallbackStep])
    let requirements = plan.permissionRequirements

    XCTAssertEqual(requirements.primary, [.automation, .accessibility])
    XCTAssertEqual(requirements.fallback, [.screenRecording])
    XCTAssertEqual(requirements.fallbackOnly, [.screenRecording])
    XCTAssertEqual(requirements.all, [.automation, .accessibility, .screenRecording])
  }
}
