import WindowManagement

/// One native instruction interpreted using its plan's platform.
public enum ActionMethod: Codable, Sendable, Equatable, Hashable {
  /// Input failed deterministic validation.
  case invalidInput(String)
  /// An adapter-specific native key event.
  case keyEvent(ActionKeyStroke)
  /// An adapter-specific media or system control key.
  case systemKey(UInt16)
  /// A shortcut expressed in the shared physical-key syntax.
  case keyEventFromKeyboardShortcut(String)
  /// An Apple Events script with the native preparation it needs.
  case appleScript(source: String, launchesSystemEvents: Bool, usesAccessibility: Bool)
  /// Open the canonical URL with its system handler.
  case openURL(String)
  /// Open a folder with the platform file manager.
  case openFolder(String)
  /// Launch the application specified for this platform.
  case launchApplication(String)
  /// Invoke a named macOS Shortcut.
  case runShortcut(String)
  /// Request hiding the active application.
  case hideFrontmostApplication
  /// Request graceful termination of the active application.
  case terminateFrontmostApplication
  /// Request locking the Windows session.
  case lockSession
  /// Ask the Windows shell to toggle the desktop view.
  case toggleDesktop
  /// Request macOS screen capture with adapter-specific arguments.
  case screenCapture(arguments: [String])
  /// Request a window operation.
  case windowing(WindowingExecution)
}

extension ActionMethod {
  /// Compares instruction values, including the exact UTF-8 of native text.
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.comparisonValue == rhs.comparisonValue
  }

  /// Hashes instruction values using the same identity as equality.
  public func hash(into hasher: inout Hasher) {
    hasher.combine(comparisonValue)
  }

  private enum ComparisonValue: Hashable {
    case text(Kind, UTF8Text)
    case empty(Kind)
    case keyEvent(ActionKeyStroke)
    case systemKey(UInt16)
    case appleScript(UTF8Text, Bool, Bool)
    case screenCapture([UTF8Text])
    case windowing(WindowingExecution)
  }

  private var comparisonValue: ComparisonValue {
    switch self {
    case .invalidInput(let value): .text(.invalidInput, UTF8Text(value))
    case .keyEvent(let value): .keyEvent(value)
    case .systemKey(let value): .systemKey(value)
    case .keyEventFromKeyboardShortcut(let value): .text(.keyboardShortcut, UTF8Text(value))
    case .appleScript(let source, let launches, let accessibility):
      .appleScript(UTF8Text(source), launches, accessibility)
    case .openURL(let value): .text(.openURL, UTF8Text(value))
    case .openFolder(let value): .text(.openFolder, UTF8Text(value))
    case .launchApplication(let value): .text(.launchApplication, UTF8Text(value))
    case .runShortcut(let value): .text(.runShortcut, UTF8Text(value))
    case .hideFrontmostApplication: .empty(.hideFrontmostApplication)
    case .terminateFrontmostApplication: .empty(.terminateFrontmostApplication)
    case .lockSession: .empty(.lockSession)
    case .toggleDesktop: .empty(.toggleDesktop)
    case .screenCapture(let values): .screenCapture(values.map(UTF8Text.init))
    case .windowing(let value): .windowing(value)
    }
  }
}

extension ActionMethod {
  package var requiredPermissions: Set<ActionPermission> {
    RustActionPlanning.metadata(for: [.init(method: self)]).permissions.primary
  }
}

/// The operation and shared request values of a window instruction.
public enum WindowingExecution: Sendable, Equatable, Hashable {
  /// Place the focused window according to the given geometry request.
  case placeFocusedWindow(WindowPlacementRequest)
  /// Move the focused window between displays.
  case moveFocusedWindow(WindowMoveRequest)
  /// Minimize the focused window.
  case minimizeFocusedWindow
  /// Toggle native full-screen state for the focused window.
  case toggleFocusedWindowFullScreen
  /// Request closing one foreground window.
  case closeForegroundWindow
}

/// Shared modifier bits. Their physical keys depend on the plan's platform.
public struct ActionModifiers: OptionSet, Sendable, Equatable, Hashable {
  /// The shared modifier bitmask.
  public let rawValue: UInt16

  /// Constructs the modifier set from its shared bitmask.
  public init(rawValue: UInt16) {
    self.rawValue = rawValue
  }

  /// Command on macOS, Windows key on Windows.
  public static let meta = Self(rawValue: 1 << 0)
  /// Shift key.
  public static let shift = Self(rawValue: 1 << 1)
  /// Option on macOS, Alt on Windows.
  public static let alt = Self(rawValue: 1 << 2)
  /// Control key.
  public static let control = Self(rawValue: 1 << 3)
  /// Function key where the adapter supports it.
  public static let function = Self(rawValue: 1 << 4)

  package static let command = meta
  package static let option = alt
}

/// One virtual key code and its modifiers.
public struct ActionKeyStroke: Sendable, Equatable, Hashable {
  /// The virtual key code for the plan's platform.
  public let virtualKeyCode: UInt16
  /// The shared modifier bits.
  public let modifiers: ActionModifiers

  package init(virtualKeyCode: UInt16, modifiers: ActionModifiers = []) {
    self.virtualKeyCode = virtualKeyCode
    self.modifiers = modifiers
  }
}

extension ActionMethod {
  package static func keyEvent(virtualKeyCode: UInt16, modifiers: ActionModifiers = []) -> Self {
    .keyEvent(.init(virtualKeyCode: virtualKeyCode, modifiers: modifiers))
  }
}
