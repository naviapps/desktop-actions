import ApplicationServices
import Synchronization

package struct KeyStrokeEventPoster: Sendable {
  private let makeKeyEvent: @Sendable (CGKeyCode, CGEventFlags, Bool) -> CGEvent?
  private let postKeyEvent: @Sendable (CGEvent) -> Void

  package init(
    makeKeyEvent: @escaping @Sendable (CGKeyCode, CGEventFlags, Bool) -> CGEvent? = {
      Self.makeKeyEvent(virtualKey: $0, flags: $1, keyDown: $2)
    },
    postKeyEvent: @escaping @Sendable (CGEvent) -> Void
  ) {
    self.makeKeyEvent = makeKeyEvent
    self.postKeyEvent = postKeyEvent
  }

  package func postKeyStroke(virtualKey: CGKeyCode, flags: CGEventFlags) -> Bool {
    postPair(virtualKey: virtualKey, flags: flags, checking: { true })
  }

  @MainActor
  package func postKeyStroke(
    virtualKey: CGKeyCode, flags: CGEventFlags, beforePosting: @MainActor () -> Bool
  ) -> Bool {
    postPair(
      virtualKey: virtualKey, flags: flags,
      checking: {
        MainActor.assumeIsolated { beforePosting() }
      })
  }

  private func postPair(
    virtualKey: CGKeyCode, flags: CGEventFlags, checking: () -> Bool
  ) -> Bool {
    guard
      let keyDownEvent = makeKeyEvent(virtualKey, flags, true),
      let keyUpEvent = makeKeyEvent(virtualKey, flags, false)
    else {
      return false
    }

    return KeyEventPair.post(keyDownEvent, keyUpEvent, using: postKeyEvent, checking: checking)
  }

  private static func makeKeyEvent(
    virtualKey: CGKeyCode,
    flags: CGEventFlags,
    keyDown: Bool
  ) -> CGEvent? {
    guard
      let event = CGEvent(
        keyboardEventSource: nil,
        virtualKey: virtualKey,
        keyDown: keyDown
      )
    else {
      return nil
    }
    event.flags = flags
    return event
  }
}

enum KeyEventPair {
  private static let posting = Mutex(())

  static func post(
    _ down: CGEvent, _ up: CGEvent, using sink: (CGEvent) -> Void, checking: () -> Bool = { true }
  ) -> Bool {
    posting.withLock { _ in
      guard !Task.isCancelled, checking(), !Task.isCancelled else { return false }
      // Once the down event is posted, always complete its pair.
      sink(down)
      sink(up)
      return true
    }
  }
}
