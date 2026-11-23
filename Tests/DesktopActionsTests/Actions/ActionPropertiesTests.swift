import DesktopActions
import WindowManagement
import XCTest

final class ActionPropertiesTests: XCTestCase {
  func testActionKindMatchesEveryActionCase() {
    let cases = ActionTestFixtures.actionKindCases

    XCTAssertEqual(cases.count, ActionKind.allCases.count)
    XCTAssertEqual(Set(cases.map(\.kind)), Set(ActionKind.allCases))
    for (action, kind) in cases {
      XCTAssertEqual(action.kind, kind)
    }
  }

  func testActionInputIsNilForInputFreeActions() {
    let inputFreeActions = ActionTestFixtures.actionKindCases.filter {
      !$0.kind.inputDescriptor.requiresInput
    }

    for (action, _) in inputFreeActions {
      XCTAssertNil(action.input, "\(action) should not expose input")
    }
  }

  func testActionInputNormalizesStringValues() {
    XCTAssertEqual(
      Set(Self.stringInputFixtures.map { $0.action.kind }),
      Set(ActionKind.allCases.filter { $0.inputDescriptor.shape == .string })
    )

    for (action, expectedInput) in Self.stringInputFixtures {
      XCTAssertEqual(action.input, expectedInput)
    }
  }

  func testActionInputRejectsBlankStringValues() {
    XCTAssertEqual(
      Set(Self.blankStringInputActions.map(\.kind)),
      Set(ActionKind.allCases.filter { $0.inputDescriptor.shape == .string })
    )

    for action in Self.blankStringInputActions {
      XCTAssertNil(action.input)
    }
  }

  func testTextRequestIdentityKeepsCanonicalVariantsAndRawWhitespaceDistinct() {
    let composed = "caf\u{00E9}"
    let decomposed = "cafe\u{0301}"
    let makeActions: [(String) -> ActionRequest] = [
      ActionRequest.keyboardShortcut, ActionRequest.openURL, ActionRequest.launchApplication,
      ActionRequest.runShortcut, ActionRequest.openFolder,
    ]

    XCTAssertEqual(
      Set(makeActions.map { $0(composed).kind }),
      Set(ActionKind.allCases.filter { $0.inputDescriptor.shape == .string })
    )
    for makeAction in makeActions {
      let original = makeAction(composed)
      let replacement = makeAction(decomposed)
      let spaced = makeAction(" \(composed) ")
      var drafts = [original: "original"]
      drafts[spaced] = "spaced"
      drafts[replacement] = "edited"

      XCTAssertEqual(original, makeAction(composed))
      XCTAssertNotEqual(original, replacement)
      XCTAssertNotEqual(original, spaced)
      XCTAssertEqual(original.input, spaced.input)
      XCTAssertEqual(drafts.count, 3)
      XCTAssertEqual(drafts[makeAction(composed)], "original")
      XCTAssertEqual(drafts[makeAction(decomposed)], "edited")
    }
  }

  func testActionInputPreservesWindowRequests() {
    let placement = WindowPlacementRequest(
      placement: .grid(columns: 2, rows: 1, column: 0, row: 0, columnSpan: 1, rowSpan: 1))
    let move = WindowMoveRequest(direction: .next, preservesRelativePosition: false)

    XCTAssertEqual(ActionRequest.windowPlacement(placement).input, .windowPlacement(placement))
    XCTAssertEqual(ActionRequest.windowMove(move).input, .windowMove(move))
  }

  private static var stringInputFixtures: [(action: ActionRequest, input: ActionInput)] {
    [
      (ActionRequest.keyboardShortcut("  cmd+c  "), .string("cmd+c")),
      (ActionRequest.openURL("  https://example.com  "), .string("https://example.com")),
      (ActionRequest.launchApplication("  Safari  "), .string("Safari")),
      (ActionRequest.runShortcut("  Daily  "), .string("Daily")),
      (ActionRequest.openFolder("  ~/Downloads  "), .string("~/Downloads")),
    ]
  }

  private static var blankStringInputActions: [ActionRequest] {
    let blank = " \n\t "

    return [
      .keyboardShortcut(blank),
      .openURL(blank),
      .launchApplication(blank),
      .runShortcut(blank),
      .openFolder(blank),
    ]
  }
}
