import DesktopActions
import XCTest

final class ActionPreflightEditingTests: XCTestCase {
  func testRedoProjectsTheNativeEditingPlanAndChord() throws {
    assertSingleAccessibilityKeyEventPlan(
      .init(action: .redo, virtualKeyCode: 6, modifiers: [.command, .shift]))
    let chord = try XCTUnwrap(ActionPreflight.macOSEditingChord(for: .redo))
    XCTAssertEqual(chord.letter, 0x7A)
    XCTAssertEqual(chord.stroke, .init(virtualKeyCode: 6, modifiers: [.command, .shift]))
    XCTAssertNil(ActionPreflight.macOSEditingChord(for: .keyboardShortcut))
  }
}
