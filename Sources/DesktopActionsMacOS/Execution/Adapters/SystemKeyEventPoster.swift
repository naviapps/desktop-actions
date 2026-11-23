import AppKit

/// Encode consumer controls as NX_SYSDEFINED/AUX_CONTROL_BUTTONS. Construct both
/// edges before posting either one, so a failed allocation cannot leave a held key.
package struct SystemKeyEventPoster: Sendable {
  private let makeEvent: @Sendable (UInt16, Bool) -> CGEvent?
  private let postEvent: @Sendable (CGEvent) -> Void

  package init(
    makeEvent: @escaping @Sendable (UInt16, Bool) -> CGEvent? = { code, down in
      let state = (down ? 10 : 11) << 8
      return NSEvent.otherEvent(
        with: .systemDefined, location: .zero,
        modifierFlags: .init(rawValue: UInt(state)), timestamp: 0, windowNumber: 0,
        context: nil, subtype: 8, data1: (Int(code) << 16) | state, data2: -1)?.cgEvent
    },
    postEvent: @escaping @Sendable (CGEvent) -> Void
  ) {
    self.makeEvent = makeEvent
    self.postEvent = postEvent
  }

  package func post(_ code: UInt16) -> Bool {
    guard let down = makeEvent(code, true), let up = makeEvent(code, false) else { return false }
    return KeyEventPair.post(down, up, using: postEvent)
  }
}
