import ApplicationServices
import DesktopActions

extension ActionExecutor {
  func executeKeyboardShortcut(_ shortcut: String) throws(CancellationError) -> ActionResult {
    guard let parsedShortcut = KeyboardShortcutParser.parse(shortcut) else {
      return invalidInputResult("Failed to parse keyboard shortcut")
    }

    return try executeKeyEvent(parsedShortcut)
  }

  func executeKeyEvent(_ event: ActionKeyStroke) throws(CancellationError) -> ActionResult {
    try executeKeyStroke(
      virtualKey: CGKeyCode(event.virtualKeyCode),
      flags: event.modifiers.toCGEventFlags()
    )
  }

  private func executeKeyStroke(virtualKey: CGKeyCode, flags: CGEventFlags)
    throws(CancellationError) -> ActionResult
  {
    let posted = dependencies.keyEventPoster.postKeyStroke(virtualKey: virtualKey, flags: flags)
    try checkCancellation()
    guard posted else {
      return internalErrorResult("Failed to post key stroke event")
    }
    return .success
  }
}

extension ActionModifiers {
  fileprivate func toCGEventFlags() -> CGEventFlags {
    var flags: CGEventFlags = []
    if contains(.command) { flags.insert(.maskCommand) }
    if contains(.shift) { flags.insert(.maskShift) }
    if contains(.option) { flags.insert(.maskAlternate) }
    if contains(.control) { flags.insert(.maskControl) }
    if contains(.function) { flags.insert(.maskSecondaryFn) }
    return flags
  }
}
