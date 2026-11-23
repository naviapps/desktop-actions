import Carbon
import DesktopActions
import Foundation
import XCTest

final class ActionTextInputKindTests: XCTestCase {
  func testKeyboardConfirmationMatchesTargetFunctionModifierSupport() throws {
    let keyboard = try XCTUnwrap(ActionTextInputKind(kind: .keyboardShortcut))
    XCTAssertTrue(keyboard.evaluate("fn+f11", platform: .macOS).canConfirm)

    let windows = keyboard.evaluate("fn+f11", platform: .windows)
    XCTAssertFalse(windows.canConfirm)
    XCTAssertEqual(windows.issue, .unsupportedPlatform)
    XCTAssertEqual(windows.confirmedValue, "fn+f11")
    XCTAssertTrue(keyboard.evaluate("ctrl+f24", platform: .windows).canConfirm)
    XCTAssertEqual(
      keyboard.evaluate("fn++f11", platform: .windows).issue, .invalidKeyboardShortcut)
  }

  func testDescriptorsAndTextFormsComeFromTheNativeCatalog() throws {
    for kind in ActionKind.allCases {
      XCTAssertEqual(kind.descriptor.kind, kind)
      XCTAssertEqual(kind.descriptor.identifier, kind.identifier)
      XCTAssertEqual(kind.descriptor.category, kind.category)
      XCTAssertEqual(kind.descriptor.inputDescriptor, kind.inputDescriptor)
      XCTAssertEqual(ActionTextInputKind(kind: kind) != nil, kind.inputDescriptor.shape == .string)
    }
    XCTAssertEqual(ActionKind.openURL.descriptor.inputForm, .url)
    XCTAssertEqual(ActionKind.openFolder.descriptor.inputForm, .folder)
  }

  func testNativeDirectoryLookupReceivesNormalizedFolderOnly() throws {
    let folder = try XCTUnwrap(ActionTextInputKind(kind: .openFolder))
    var paths: [String] = []
    let result = folder.evaluate(
      " /fixture/Example\u{200B} \n",
      directoryExists: {
        paths.append($0)
        return false
      })
    XCTAssertEqual(paths, ["/fixture/Example\u{200B}"])
    XCTAssertEqual(result.issue, .directoryUnavailable)
    XCTAssertFalse(result.canConfirm)
    _ = folder.evaluate(
      " \n",
      directoryExists: { _ in
        XCTFail("Empty path lookup")
        return false
      })
    _ = folder.evaluate(
      "bad\0value",
      directoryExists: { _ in
        XCTFail("Invalid path lookup")
        return false
      })
    let url = try XCTUnwrap(ActionTextInputKind(kind: .openURL))
    _ = url.evaluate(
      "https://example.com",
      directoryExists: { _ in
        XCTFail("Unrelated lookup")
        return false
      })
  }

  func testShortcutEvaluationProjectsProposedValueAndTypedIssue() throws {
    let input = try XCTUnwrap(ActionTextInputKind(kind: .runShortcut))
    let draft = "  \u{200B}Morning  "
    let exact = input.evaluate(draft, shortcuts: ["Morning", "\u{200B}Morning"])
    XCTAssertEqual(exact.confirmedValue, "\u{200B}Morning")
    XCTAssertTrue(exact.canConfirm)
    XCTAssertEqual(
      input.evaluate("MORNING", shortcuts: ["Morning", "morning"]).issue, .ambiguousShortcut)
    XCTAssertEqual(input.evaluate("MORNING", shortcuts: ["Morning"]).confirmedValue, "Morning")
    XCTAssertEqual(input.evaluate("Morning", platform: .windows).issue, .unsupportedPlatform)
  }

  func testTextInputUsesExecutableValidationAndDoesNotRepairInvalidPayloads() throws {
    let url = try XCTUnwrap(ActionTextInputKind(kind: .openURL))
    let invalid = url.evaluate("bad\0value")
    XCTAssertEqual(invalid.issue, .invalidURL)
    XCTAssertFalse(invalid.canConfirm)
    XCTAssertEqual(invalid.normalizedValue, "bad\0value")
    let keyboard = try XCTUnwrap(ActionTextInputKind(kind: .keyboardShortcut))
    XCTAssertEqual(keyboard.evaluate("cmd").issue, .invalidKeyboardShortcut)
    XCTAssertTrue(keyboard.evaluate("cmd+k").canConfirm)
  }

  func testBareReturnSymbolConfirmsAndKeepsTheCommandReturnKey() throws {
    let keyboard = try XCTUnwrap(ActionTextInputKind(kind: .keyboardShortcut))
    let bare = "⌘\u{21A9}"
    let evaluation = keyboard.evaluate(" \(bare) \n")
    guard evaluation.canConfirm else {
      return XCTFail("The bare U+21A9 Return symbol must be confirmable as Command-Return.")
    }
    XCTAssertNil(evaluation.issue)
    XCTAssertEqual(evaluation.confirmedValue, bare)

    let action = try XCTUnwrap(keyboard.makeAction(input: evaluation.confirmedValue))
    let restored = try JSONDecoder().decode(ActionRequest.self, from: JSONEncoder().encode(action))
    XCTAssertEqual(restored, .keyboardShortcut(bare))
    XCTAssertTrue(ActionPreflight.isExecutable(restored))
    for shortcut in [bare, "⌘\u{21A9}\u{FE0E}", "cmd+return"] {
      let stroke = try XCTUnwrap(KeyboardShortcutParser.parse(shortcut))
      XCTAssertEqual(stroke.virtualKeyCode, UInt16(kVK_Return))
      XCTAssertEqual(stroke.modifiers, .command)
    }
  }
}
