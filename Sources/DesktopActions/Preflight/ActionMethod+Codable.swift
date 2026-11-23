import WindowManagement

extension ActionMethod {
  enum Kind: String, Codable {
    case invalidInput = "invalid-input"
    case keyEvent = "key-event"
    case systemKey = "system-key"
    case keyboardShortcut = "keyboard-shortcut"
    case appleScript = "apple-script"
    case openURL = "open-url"
    case openFolder = "open-folder"
    case launchApplication = "launch-application"
    case runShortcut = "run-shortcut"
    case windowMinimize = "window-minimize"
    case windowToggleFullScreen = "window-toggle-full-screen"
    case windowClose = "window-close"
    case hideFrontmostApplication = "hide-frontmost-application"
    case terminateFrontmostApplication = "terminate-frontmost-application"
    case lockSession = "lock-session"
    case toggleDesktop = "toggle-desktop"
    case screenCapture = "screen-capture"
    case windowPlacement = "window-placement"
    case windowMove = "window-move"
  }
  private enum Keys: String, CodingKey {
    case kind, keyCode, modifiers, code, value, source, launchesSystemEvents, usesAccessibility
    case arguments, request, message
  }
  /// Decodes the tagged native instruction and its payload.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    switch try c.decode(Kind.self, forKey: .kind) {
    case .invalidInput: self = try .invalidInput(c.decode(String.self, forKey: .message))
    case .keyEvent:
      self = try .keyEvent(
        virtualKeyCode: c.decode(UInt16.self, forKey: .keyCode),
        modifiers: .init(rawValue: c.decode(UInt16.self, forKey: .modifiers)))
    case .systemKey: self = try .systemKey(c.decode(UInt16.self, forKey: .code))
    case .keyboardShortcut:
      self = try .keyEventFromKeyboardShortcut(c.decode(String.self, forKey: .value))
    case .appleScript:
      self = try .appleScript(
        source: c.decode(String.self, forKey: .source),
        launchesSystemEvents: c.decode(Bool.self, forKey: .launchesSystemEvents),
        usesAccessibility: c.decode(Bool.self, forKey: .usesAccessibility))
    case .openURL: self = try .openURL(c.decode(String.self, forKey: .value))
    case .openFolder: self = try .openFolder(c.decode(String.self, forKey: .value))
    case .launchApplication: self = try .launchApplication(c.decode(String.self, forKey: .value))
    case .runShortcut: self = try .runShortcut(c.decode(String.self, forKey: .value))
    case .hideFrontmostApplication: self = .hideFrontmostApplication
    case .terminateFrontmostApplication: self = .terminateFrontmostApplication
    case .lockSession: self = .lockSession
    case .toggleDesktop: self = .toggleDesktop
    case .screenCapture:
      self = try .screenCapture(arguments: c.decode([String].self, forKey: .arguments))
    case .windowMinimize: self = .windowing(.minimizeFocusedWindow)
    case .windowToggleFullScreen: self = .windowing(.toggleFocusedWindowFullScreen)
    case .windowClose: self = .windowing(.closeForegroundWindow)
    case .windowPlacement:
      self = try .windowing(
        .placeFocusedWindow(c.decode(WindowPlacementRequest.self, forKey: .request)))
    case .windowMove:
      self = try .windowing(.moveFocusedWindow(c.decode(WindowMoveRequest.self, forKey: .request)))
    }
  }
  /// Encodes the tagged native instruction and its payload.
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: Keys.self)
    switch self {
    case .invalidInput(let message):
      try c.encode(Kind.invalidInput, forKey: .kind)
      try c.encode(message, forKey: .message)
    case .keyEvent(let event):
      try c.encode(Kind.keyEvent, forKey: .kind)
      try c.encode(event.virtualKeyCode, forKey: .keyCode)
      try c.encode(event.modifiers.rawValue, forKey: .modifiers)
    case .systemKey(let code):
      try c.encode(Kind.systemKey, forKey: .kind)
      try c.encode(code, forKey: .code)
    case .keyEventFromKeyboardShortcut(let value):
      try c.encode(Kind.keyboardShortcut, forKey: .kind)
      try c.encode(value, forKey: .value)
    case .appleScript(let source, let launches, let accessibility):
      try c.encode(Kind.appleScript, forKey: .kind)
      try c.encode(source, forKey: .source)
      try c.encode(launches, forKey: .launchesSystemEvents)
      try c.encode(accessibility, forKey: .usesAccessibility)
    case .openURL(let value):
      try c.encode(Kind.openURL, forKey: .kind)
      try c.encode(value, forKey: .value)
    case .openFolder(let value):
      try c.encode(Kind.openFolder, forKey: .kind)
      try c.encode(value, forKey: .value)
    case .launchApplication(let value):
      try c.encode(Kind.launchApplication, forKey: .kind)
      try c.encode(value, forKey: .value)
    case .runShortcut(let value):
      try c.encode(Kind.runShortcut, forKey: .kind)
      try c.encode(value, forKey: .value)
    case .hideFrontmostApplication: try c.encode(Kind.hideFrontmostApplication, forKey: .kind)
    case .terminateFrontmostApplication:
      try c.encode(Kind.terminateFrontmostApplication, forKey: .kind)
    case .lockSession: try c.encode(Kind.lockSession, forKey: .kind)
    case .toggleDesktop: try c.encode(Kind.toggleDesktop, forKey: .kind)
    case .screenCapture(let arguments):
      try c.encode(Kind.screenCapture, forKey: .kind)
      try c.encode(arguments, forKey: .arguments)
    case .windowing(.closeForegroundWindow):
      try c.encode(Kind.windowClose, forKey: .kind)
    case .windowing(.minimizeFocusedWindow):
      try c.encode(Kind.windowMinimize, forKey: .kind)
    case .windowing(.toggleFocusedWindowFullScreen):
      try c.encode(Kind.windowToggleFullScreen, forKey: .kind)
    case .windowing(.placeFocusedWindow(let request)):
      try c.encode(Kind.windowPlacement, forKey: .kind)
      try c.encode(request, forKey: .request)
    case .windowing(.moveFocusedWindow(let request)):
      try c.encode(Kind.windowMove, forKey: .kind)
      try c.encode(request, forKey: .request)
    }
  }
}
