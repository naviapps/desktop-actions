import WindowManagement

/// A concrete desktop action with any required host-supplied input attached.
///
/// Use ``ActionKind`` for catalog and picker surfaces before input is available. Use `ActionRequest`
/// after the host has enough information to preflight, encode, persist, or execute a concrete
/// request. Equality and hashing use the action kind and its unnormalized input. String payloads
/// are trimmed by ``input``, coding, and live execution paths; those boundaries reject empty strings.
public enum ActionRequest: Codable, Hashable, Sendable {
  /// Copies the current selection.
  case copy
  /// Pastes from the clipboard.
  case paste
  /// Cuts the current selection.
  case cut
  /// Undoes the last edit action.
  case undo
  /// Redoes the last undone edit action.
  case redo
  /// Selects all content in the current editing context.
  case selectAll
  /// Invokes the current application's conventional Find shortcut.
  case findInApp

  /// Hides the frontmost application.
  case hideFrontmostApplication
  /// Requests graceful termination of the entire frontmost application (macOS only).
  case quitFrontmostApplication

  /// Raises the output volume.
  case volumeUp
  /// Lowers the output volume.
  case volumeDown
  /// Toggles output mute.
  case toggleAudioMute
  /// Toggles media playback.
  case mediaPlayPause
  /// Skips to the next media item.
  case mediaNext
  /// Skips to the previous media item.
  case mediaPrevious

  /// Sends a host-supplied keyboard shortcut string.
  case keyboardShortcut(String)
  /// Opens a host-supplied URL string.
  case openURL(String)
  /// Launches an application. macOS accepts a name, bundle identifier or .app path;
  /// Windows requires an absolute .exe path.
  case launchApplication(String)
  /// Runs a host-supplied Shortcuts shortcut name.
  case runShortcut(String)
  /// Opens a host-supplied folder path.
  case openFolder(String)

  /// Shows the window overview: Mission Control on macOS, Task View on Windows.
  case showWindowOverview
  /// Shows the desktop.
  case showDesktop
  /// Locks the current user session.
  case lockScreen
  /// Requests system sleep on supported platforms.
  case sleepSystem
  /// Switches to the next existing virtual desktop (a Space on macOS).
  case switchToNextVirtualDesktop
  /// Switches to the previous existing virtual desktop (a Space on macOS).
  case switchToPreviousVirtualDesktop
  /// Opens Mission Control App Expose for the frontmost application (macOS only).
  case missionControlAppExpose
  /// Raises display brightness.
  case brightnessUp
  /// Lowers display brightness.
  case brightnessDown
  /// Toggles the system appearance.
  case toggleAppearance
  /// Shows Notification Center.
  case showNotificationCenter
  /// Captures the full screen.
  case captureScreenFull
  /// Captures a user-selected screen region.
  case captureScreenSelection
  /// Captures a user-selected window.
  case captureScreenWindow

  /// Places the focused window using an explicit placement request.
  case windowPlacement(WindowPlacementRequest)
  /// Moves the focused window using an explicit display movement request.
  case windowMove(WindowMoveRequest)
  /// Minimizes the focused window without closing its application.
  case minimizeFocusedWindow
  /// Toggles the focused window's native full-screen state (macOS only).
  case toggleFocusedWindowFullScreen
  /// Requests an ordinary close of one foreground window, allowing save prompts or refusal.
  case closeForegroundWindow

}
