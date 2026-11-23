import CDesktopActions
import Foundation

extension ActionPreflight {
  /// Checks the same shortcut syntax and macOS ANSI key vocabulary used by the executor.
  ///
  /// Accepts symbol or named modifiers, aliases and shifted punctuation. Duplicate
  /// modifiers, unknown keys and empty separator components fail. This only parses
  /// input; it does not inspect the current keyboard layout or post key events.
  public static func isValidKeyboardShortcut(_ value: String) -> Bool {
    isValidKeyboardShortcut(value, on: .macOS)
  }

  /// Checks the shared shortcut parser and the requested adapter's physical key vocabulary.
  public static func isValidKeyboardShortcut(_ value: String, on platform: ActionPlatform) -> Bool {
    isExecutable(.keyboardShortcut(value), on: platform)
  }

  package static func macOSEditingChord(for kind: ActionKind) -> (
    letter: UInt16, stroke: ActionKeyStroke
  )? {
    Data(kind.identifier.utf8).withUnsafeBytes { bytes in
      let result = desktop_actions_macos_editing_chord(
        bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
      guard result.letter != 0 else { return nil }
      return (
        letter: result.letter,
        stroke: .init(
          virtualKeyCode: result.key_code, modifiers: .init(rawValue: result.modifiers))
      )
    }
  }
}
