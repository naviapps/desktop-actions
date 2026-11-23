import DesktopActions

extension ActionKind {
  /// Standard SF Symbol artwork. Hosts may supply their own artwork and localized titles.
  public var standardSystemImage: String {
    switch self {
    case .copy: "doc.on.doc"
    case .paste: "doc.on.clipboard"
    case .cut: "scissors"
    case .undo: "arrow.uturn.backward"
    case .redo: "arrow.uturn.forward"
    case .selectAll: "square.dashed"
    case .findInApp: "magnifyingglass"
    case .hideFrontmostApplication: "app.badge.fill"
    case .quitFrontmostApplication: "power"
    case .closeForegroundWindow: "xmark.rectangle"
    case .volumeUp: "speaker.wave.3"
    case .volumeDown: "speaker.wave.1"
    case .toggleAudioMute: "speaker.slash"
    case .mediaPlayPause: "playpause"
    case .mediaNext: "forward.fill"
    case .mediaPrevious: "backward.fill"
    case .minimizeFocusedWindow: "minus.rectangle"
    case .toggleFocusedWindowFullScreen: "arrow.up.left.and.arrow.down.right"
    case .windowPlacement: "rectangle.inset.filled"
    case .windowMove: "display.2"
    case .showWindowOverview: "rectangle.3.offgrid"
    case .switchToNextVirtualDesktop: "arrow.right.circle"
    case .switchToPreviousVirtualDesktop: "arrow.left.circle"
    case .missionControlAppExpose: "rectangle.stack.person.crop"
    case .showDesktop: "macwindow"
    case .lockScreen: "lock.display"
    case .sleepSystem: "moon.zzz"
    case .brightnessUp: "sun.max"
    case .brightnessDown: "sun.min"
    case .toggleAppearance: "circle.lefthalf.filled"
    case .showNotificationCenter: "app.badge"
    case .captureScreenFull: "camera.fill"
    case .captureScreenSelection: "scissors"
    case .captureScreenWindow: "macwindow.on.rectangle"
    case .keyboardShortcut: "command"
    case .openURL: "link"
    case .launchApplication: "app"
    case .runShortcut: "bolt"
    case .openFolder: "folder"
    }
  }
}
