import CDesktopActions

package enum KeyboardShortcutParser {
  package static func parse(_ shortcut: String) -> ActionKeyStroke? {
    let bytes = Array(shortcut.utf8)
    let result = bytes.withUnsafeBufferPointer {
      desktop_actions_parse_shortcut($0.baseAddress, $0.count)
    }
    guard result.code == 0 else { return nil }
    let keyCode = desktop_actions_macos_key_code(result.stroke.usage)
    guard let keyCode = UInt16(exactly: keyCode) else { return nil }
    return .init(virtualKeyCode: keyCode, modifiers: .init(rawValue: result.stroke.modifiers))
  }
}
