/// Native adapter with an implementation for an action kind.
public enum ActionPlatform: String, CaseIterable, Codable, Hashable, Sendable {
  /// AppKit, Accessibility and macOS integrations.
  case macOS = "macos"
  /// Windows desktop integrations.
  case windows
}
