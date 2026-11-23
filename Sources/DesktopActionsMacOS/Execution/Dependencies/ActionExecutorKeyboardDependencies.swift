import ApplicationServices

package protocol KeyEventPosting: Sendable {
  func postKeyStroke(virtualKey: CGKeyCode, flags: CGEventFlags) -> Bool
  @MainActor
  func postKeyStroke(
    virtualKey: CGKeyCode, flags: CGEventFlags, beforePosting: @MainActor () -> Bool
  ) -> Bool
  func postSystemKey(_ code: UInt16) -> Bool
}
