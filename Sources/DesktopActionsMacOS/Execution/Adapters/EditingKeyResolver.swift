import Carbon
import Foundation

/// Resolves the letters used by dedicated editing actions against a current macOS layout.
package struct EditingKeyResolver: Sendable {
  package enum Letter: UInt16, Sendable {
    case a = 0x61
    case c = 0x63
    case f = 0x66
    case v = 0x76
    case x = 0x78
    case z = 0x7A

    fileprivate func matches(_ character: UInt16?) -> Bool {
      character == rawValue || character == rawValue - 0x20
    }
  }

  package struct Layout: Sendable {
    private let selectedSourceIdentifier: String
    private let effectiveLayoutIdentifier: String
    private let keyboardType: UInt32
    private let data: Data
    fileprivate let translate: @MainActor @Sendable (UInt16, Bool) -> UInt16?

    package init(
      selectedSourceIdentifier: String, effectiveLayoutIdentifier: String, keyboardType: UInt32,
      data: Data, translate: @escaping @MainActor @Sendable (UInt16, Bool) -> UInt16?
    ) {
      self.selectedSourceIdentifier = selectedSourceIdentifier
      self.effectiveLayoutIdentifier = effectiveLayoutIdentifier
      self.keyboardType = keyboardType
      self.data = data
      self.translate = translate
    }

    fileprivate func identifiesSameLayout(as other: Self) -> Bool {
      selectedSourceIdentifier == other.selectedSourceIdentifier
        && effectiveLayoutIdentifier == other.effectiveLayoutIdentifier
        && keyboardType == other.keyboardType && data == other.data
    }
  }

  package struct Match: Sendable {
    package let virtualKey: UInt16
    fileprivate let letter: Letter
    fileprivate let shift: Bool
    fileprivate let layout: Layout
  }

  private let snapshot: @MainActor @Sendable () -> Layout?

  package init(snapshot: @escaping @MainActor @Sendable () -> Layout?) {
    self.snapshot = snapshot
  }

  package static let live = Self(snapshot: { liveLayout() })

  @MainActor
  package func resolve(_ letter: Letter, shift: Bool) -> Match? {
    guard let layout = snapshot() else { return nil }
    var matched: UInt16?
    for key in UInt16(0)...127 where letter.matches(layout.translate(key, shift)) {
      guard matched == nil else { return nil }
      matched = key
    }
    guard let matched else { return nil }
    return Match(virtualKey: matched, letter: letter, shift: shift, layout: layout)
  }

  @MainActor
  package func isCurrent(_ match: Match) -> Bool {
    guard let current = snapshot(), match.layout.identifiesSameLayout(as: current) else {
      return false
    }
    return match.letter.matches(current.translate(match.virtualKey, match.shift))
  }

  @MainActor
  private static func liveLayout() -> Layout? {
    let keyboardType = UInt32(LMGetKbdType())
    guard let selected = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
      let selectedID = sourceIdentifier(selected),
      let layout = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
      let layoutID = sourceIdentifier(layout),
      let data = layoutData(layout),
      let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
      sourceIdentifier(current) == selectedID,
      let currentLayout = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
      sourceIdentifier(currentLayout) == layoutID, UInt32(LMGetKbdType()) == keyboardType
    else { return nil }
    return Layout(
      selectedSourceIdentifier: selectedID, effectiveLayoutIdentifier: layoutID,
      keyboardType: keyboardType, data: data,
      translate: { key, shift in
        translate(key, shift: shift, data: data, keyboardType: keyboardType)
      })
  }

  @MainActor
  private static func sourceIdentifier(_ source: TISInputSource) -> String? {
    guard let property = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
    else { return nil }
    return withExtendedLifetime(source) {
      let identifier = Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue()
      guard CFGetTypeID(identifier) == CFStringGetTypeID() else { return nil }
      let value = identifier as String
      return value.isEmpty ? nil : value
    }
  }

  @MainActor
  private static func layoutData(_ source: TISInputSource) -> Data? {
    guard let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else { return nil }
    return withExtendedLifetime(source) {
      let native = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
      guard CFGetTypeID(native) == CFDataGetTypeID() else { return nil }
      let count = CFDataGetLength(native)
      guard (MemoryLayout<UCKeyboardLayout>.size...1_048_576).contains(count),
        let bytes = CFDataGetBytePtr(native)
      else { return nil }
      return Data(bytes: bytes, count: count)
    }
  }

  private static func translate(
    _ key: UInt16, shift: Bool, data: Data, keyboardType: UInt32
  ) -> UInt16? {
    data.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress,
        Int(bitPattern: base) % MemoryLayout<UCKeyboardLayout>.alignment == 0
      else { return nil }
      let modifiers = (UInt32(cmdKey) | (shift ? UInt32(shiftKey) : 0)) >> 8
      var deadKeyState: UInt32 = 0
      var count = 0
      var character: UniChar = 0
      // The dead-key state is local: rejecting a nonzero state never affects text input.
      let status = UCKeyTranslate(
        base.assumingMemoryBound(to: UCKeyboardLayout.self), key, UInt16(kUCKeyActionDown),
        modifiers, keyboardType, 0, &deadKeyState, 1, &count, &character)
      return status == noErr && deadKeyState == 0 && count == 1 ? character : nil
    }
  }
}
