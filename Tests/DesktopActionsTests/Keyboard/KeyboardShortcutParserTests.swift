import Carbon
import DesktopActions
import XCTest

final class KeyboardShortcutParserTests: XCTestCase {
  func testSymbolicShortcutProjectsTheNativeKeyAndCombinedModifiers() throws {
    let stroke = try XCTUnwrap(KeyboardShortcutParser.parse("⌘⇧C"))
    XCTAssertEqual(stroke.virtualKeyCode, UInt16(kVK_ANSI_C))
    XCTAssertEqual(stroke.modifiers, [.command, .shift])
  }

  func testFunctionModifierProjectsTheNativeKeyAndFlag() throws {
    let stroke = try XCTUnwrap(KeyboardShortcutParser.parse("fn forward-delete"))
    XCTAssertEqual(stroke.virtualKeyCode, UInt16(kVK_ForwardDelete))
    XCTAssertEqual(stroke.modifiers, .function)
  }

  func testMalformedAndUnmappedShortcutsDoNotProduceNativeStrokes() {
    XCTAssertNil(KeyboardShortcutParser.parse("⌘++C"))
    XCTAssertNil(KeyboardShortcutParser.parse("f24"))
  }
}
