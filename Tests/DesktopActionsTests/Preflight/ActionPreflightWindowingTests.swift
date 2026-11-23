import DesktopActions
import WindowManagement
import XCTest

final class ActionPreflightWindowingTests: XCTestCase {
  func testCloseSelectsOneNativeWindowRequestWithoutAKeyboardFallback() {
    XCTAssertEqual(
      assertWindowingExecution(for: .closeForegroundWindow), .closeForegroundWindow)
  }

  func testToggleFullScreenSelectsOneNativeWindowRequestWithoutAKeyboardFallback() {
    XCTAssertEqual(
      assertWindowingExecution(for: .toggleFocusedWindowFullScreen), .toggleFocusedWindowFullScreen)
  }

  func testTypedPlacementAndMovementRequestsProjectOnBothPlatforms() {
    let placement = WindowPlacementRequest(
      placement: .grid(columns: 2, rows: 2, column: 1, row: 0, columnSpan: 1, rowSpan: 2),
      display: .displayIdentifier(UInt64.max),
      area: .full,
      inset: 8
    )
    let move = WindowMoveRequest(direction: .previous, preservesRelativePosition: false)
    for platform in [ActionPlatform.macOS, .windows] {
      XCTAssertEqual(
        assertWindowingExecution(for: .windowPlacement(placement), platform: platform),
        .placeFocusedWindow(placement)
      )
      XCTAssertEqual(
        assertWindowingExecution(for: .windowMove(move), platform: platform),
        .moveFocusedWindow(move)
      )
    }
  }

  private func assertWindowingExecution(
    for action: ActionRequest,
    platform: ActionPlatform = .macOS,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> WindowingExecution? {
    let plan = action.plan(for: platform)

    XCTAssertEqual(plan.steps.count, 1, file: file, line: line)
    XCTAssertEqual(
      plan.permissionRequirements,
      .init(primary: platform == .macOS ? [.accessibility] : [], fallback: []),
      file: file,
      line: line
    )

    guard case .windowing(let execution) = plan.steps.first?.method else {
      XCTFail("Expected windowing execution for \(action)", file: file, line: line)
      return nil
    }

    return execution
  }
}
