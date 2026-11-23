import ApplicationServices

struct LiveKeyEventPoster: KeyEventPosting {
  private let keyStrokePoster: KeyStrokeEventPoster

  init() {
    keyStrokePoster = KeyStrokeEventPoster(postKeyEvent: { event in
      event.post(tap: .cghidEventTap)
    })
  }

  func postKeyStroke(virtualKey: CGKeyCode, flags: CGEventFlags) -> Bool {
    keyStrokePoster.postKeyStroke(virtualKey: virtualKey, flags: flags)
  }

  @MainActor
  func postKeyStroke(
    virtualKey: CGKeyCode, flags: CGEventFlags, beforePosting: @MainActor () -> Bool
  ) -> Bool {
    keyStrokePoster.postKeyStroke(
      virtualKey: virtualKey, flags: flags, beforePosting: beforePosting)
  }

  func postSystemKey(_ code: UInt16) -> Bool {
    SystemKeyEventPoster { $0.post(tap: .cghidEventTap) }.post(code)
  }
}
