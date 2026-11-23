extension ActionRequest {
  /// Inspects the Rust-selected instructions and permission metadata for the given platform.
  /// Planning never queries permissions, discovers targets, or executes native effects.
  public func plan(for platform: ActionPlatform) -> ActionPlan {
    RustActionPlanning.plan(for: self, on: platform)
  }

  /// The action kind represented by this action.
  public var kind: ActionKind {
    switch self {
    case .copy: .copy
    case .paste: .paste
    case .cut: .cut
    case .undo: .undo
    case .redo: .redo
    case .selectAll: .selectAll
    case .findInApp: .findInApp
    case .hideFrontmostApplication: .hideFrontmostApplication
    case .quitFrontmostApplication: .quitFrontmostApplication
    case .volumeUp: .volumeUp
    case .volumeDown: .volumeDown
    case .toggleAudioMute: .toggleAudioMute
    case .mediaPlayPause: .mediaPlayPause
    case .mediaNext: .mediaNext
    case .mediaPrevious: .mediaPrevious
    case .keyboardShortcut: .keyboardShortcut
    case .openURL: .openURL
    case .launchApplication: .launchApplication
    case .runShortcut: .runShortcut
    case .openFolder: .openFolder
    case .showWindowOverview: .showWindowOverview
    case .showDesktop: .showDesktop
    case .lockScreen: .lockScreen
    case .sleepSystem: .sleepSystem
    case .switchToNextVirtualDesktop: .switchToNextVirtualDesktop
    case .switchToPreviousVirtualDesktop: .switchToPreviousVirtualDesktop
    case .missionControlAppExpose: .missionControlAppExpose
    case .brightnessUp: .brightnessUp
    case .brightnessDown: .brightnessDown
    case .toggleAppearance: .toggleAppearance
    case .showNotificationCenter: .showNotificationCenter
    case .captureScreenFull: .captureScreenFull
    case .captureScreenSelection: .captureScreenSelection
    case .captureScreenWindow: .captureScreenWindow
    case .windowPlacement: .windowPlacement
    case .windowMove: .windowMove
    case .minimizeFocusedWindow: .minimizeFocusedWindow
    case .toggleFocusedWindowFullScreen: .toggleFocusedWindowFullScreen
    case .closeForegroundWindow: .closeForegroundWindow
    }
  }

  /// The normalized input carried by this action.
  ///
  /// Input-free actions and string-backed actions with empty normalized input return `nil`.
  public var input: ActionInput? {
    rawInput?.normalized
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.kind == rhs.kind && lhs.rawInput == rhs.rawInput
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(kind)
    hasher.combine(rawInput)
  }

  private var rawInput: ActionInput? {
    switch self {
    case .keyboardShortcut(let value),
      .openURL(let value),
      .launchApplication(let value),
      .runShortcut(let value),
      .openFolder(let value):
      return .string(value)
    case .windowPlacement(let request):
      return .windowPlacement(request)
    case .windowMove(let request):
      return .windowMove(request)
    case .copy, .paste, .cut, .undo, .redo, .selectAll, .findInApp, .hideFrontmostApplication,
      .quitFrontmostApplication,
      .volumeUp, .volumeDown, .toggleAudioMute, .mediaPlayPause, .mediaNext, .mediaPrevious,
      .showWindowOverview, .showDesktop, .lockScreen, .sleepSystem, .switchToNextVirtualDesktop,
      .switchToPreviousVirtualDesktop, .missionControlAppExpose, .brightnessUp, .brightnessDown,
      .toggleAppearance, .showNotificationCenter, .captureScreenFull, .captureScreenSelection,
      .captureScreenWindow, .minimizeFocusedWindow, .toggleFocusedWindowFullScreen,
      .closeForegroundWindow:
      return nil
    }
  }
}
