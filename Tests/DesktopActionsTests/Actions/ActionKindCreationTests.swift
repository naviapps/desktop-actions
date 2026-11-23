import DesktopActions
import XCTest

final class ActionKindCreationTests: XCTestCase {
  func testMakeActionCreatesActionsForAllInputRequiringKinds() {
    let fixtures = ActionTestFixtures.inputActionCases
    let inputRequiringKinds = ActionKind.allCases.filter { $0.inputDescriptor.shape != .none }

    XCTAssertEqual(fixtures.count, inputRequiringKinds.count)
    XCTAssertEqual(Set(fixtures.map(\.kind)), Set(inputRequiringKinds))
    for (kind, input, action) in fixtures {
      XCTAssertEqual(kind.makeAction(input: input), action)
    }
  }

  func testInputDescriptorExamplesCreateMatchingActions() {
    for kind in ActionKind.allCases {
      let action: ActionRequest?
      if let exampleInput = kind.inputDescriptor.exampleInput {
        action = kind.makeAction(input: exampleInput)
      } else {
        action = kind.makeAction()
      }

      XCTAssertEqual(action?.kind, kind, "\(kind) descriptor example should create its action")
    }
  }

  func testMakeActionReturnsNilForUnexpectedMissingMismatchedAndBlankInputs() {
    XCTAssertNil(ActionKind.copy.makeAction(input: .string("value")))
    XCTAssertNil(ActionKind.openURL.makeAction())
    XCTAssertNil(ActionKind.openURL.makeAction(input: .windowMove(.init(direction: .next))))
    XCTAssertNil(ActionKind.keyboardShortcut.makeAction(input: .string(" ")))
  }

  func testMakeActionProjectsNormalizedTextIntoTheSwiftAction() {
    let value = "https://example.com"
    let action = ActionKind.openURL.makeAction(input: .string(" \u{2003}\(value)\n"))

    XCTAssertEqual(action, .openURL(value))
    XCTAssertEqual(action?.input, .string(value))
  }
}
