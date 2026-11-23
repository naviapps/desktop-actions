import DesktopActions
import XCTest

final class ActionPreflightWorkspaceTests: XCTestCase {
  func testPublicExecutablePreflightUsesSharedInputValidationWithoutChangingSavedValues() {
    XCTAssertFalse(ActionPreflight.isExecutable(.openURL("https://")))
    let action = ActionRequest.openURL("custom:日本")
    XCTAssertTrue(ActionPreflight.isExecutable(action))
    XCTAssertEqual(action.input, .string("custom:日本"))
  }

  func testBlankWorkspaceConvenienceRequestsAreNotExecutable() {
    XCTAssertFalse(ActionPreflight.isExecutable(.launchApplication("  ")))
    XCTAssertFalse(ActionPreflight.isExecutable(.runShortcut("")))
  }

  func testWorkspacePlanProjectsNormalizedFolder() {
    assertWorkspaceMethod(for: .openFolder("  /tmp  "), equals: .openFolder("/tmp"))
  }

  func testDistinctURLPathsSurviveCodingAndRustPlanning() throws {
    let composed = ActionRequest.openURL("https://example.invalid/caf\u{00E9}")
    let decomposed = ActionRequest.openURL("https://example.invalid/cafe\u{0301}")
    let first = try ActionCodec.decode(ActionCodec.encode(composed))
    let second = try ActionCodec.decode(ActionCodec.encode(decomposed))

    XCTAssertEqual(first, composed)
    XCTAssertEqual(second, decomposed)
    XCTAssertNotEqual(first, second)
    assertWorkspaceMethod(for: first, equals: .openURL("https://example.invalid/caf%C3%A9"))
    assertWorkspaceMethod(for: second, equals: .openURL("https://example.invalid/cafe%CC%81"))
  }

  private func assertWorkspaceMethod(
    for action: ActionRequest,
    equals method: ActionMethod,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let plan = ActionPreflight.plan(for: action)

    XCTAssertEqual(plan.steps.count, 1, file: file, line: line)
    XCTAssertEqual(plan.steps.first?.method, method, file: file, line: line)
    XCTAssertEqual(
      plan.permissionRequirements,
      .init(primary: [], fallback: []),
      file: file,
      line: line
    )
  }
}
