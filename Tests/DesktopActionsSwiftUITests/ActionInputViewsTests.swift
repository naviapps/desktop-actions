import AppKit
import DesktopActions
import DesktopActionsSwiftUI
import SwiftUI
import XCTest

@MainActor
final class ActionInputViewsTests: XCTestCase {
  func testControlsMountWithoutChangingDraftOrInvokingNativePicker() throws {
    var draft = "  \u{200B}Morning  "
    var pickerCalls = 0
    let binding = Binding(get: { draft }, set: { draft = $0 })
    let kind = try XCTUnwrap(ActionTextInputKind(kind: .keyboardShortcut))
    let view = NSHostingView(
      rootView: VStack {
        InputHarness(
          kind: kind, value: binding)
        ActionSelectionInput(value: "Example", placeholder: "Select") {
          Button("Browse") { pickerCalls += 1 }
        }
        ActionShortcutMenu(names: ["Morning", "morning"], value: binding, title: "Choose")
      })
    view.frame = NSRect(x: 0, y: 0, width: 460, height: 240)
    view.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(view.fittingSize.height, 0)
    XCTAssertEqual(draft, "  \u{200B}Morning  ")
    XCTAssertEqual(pickerCalls, 0)
  }

  func testStandardSymbolsCoverTheNativeCatalog() {
    for kind in ActionKind.allCases {
      XCTAssertNotNil(
        NSImage(systemSymbolName: kind.standardSystemImage, accessibilityDescription: nil))
    }
  }
}

private struct InputHarness: View {
  let kind: ActionTextInputKind
  @Binding var value: String
  @FocusState private var focus: Bool

  var body: some View {
    ActionTextInputField(
      kind: kind, value: $value, placeholder: "Input", title: Text("Action input"),
      focus: $focus, valueIdentifier: "test-input", keyboardHint: "Use a modifier",
      clearTitle: "Clear")
  }
}
