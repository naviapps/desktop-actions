/// Canonical categories for execution failures.
public enum ActionErrorCode: String, Codable, Hashable, CaseIterable, Sendable {
  /// The action input was empty, malformed, or unsupported.
  case invalidInput = "invalid-input"
  /// A required macOS permission was denied or unavailable.
  case permissionDenied = "permission-denied"
  /// A requested URL, file path, application, or resource was not found.
  case notFound = "not-found"
  /// The system failed to open or launch a requested resource.
  case openFailed = "open-failed"
  /// AppleScript execution failed.
  case appleScriptFailed = "apple-script-failed"
  /// Screen capture execution failed.
  case screenCaptureFailed = "screen-capture-failed"
  /// An unexpected internal execution failure occurred.
  case internalError = "internal-error"
  /// The selected operation has no implementation on the target platform.
  case unsupportedAction = "unsupported-action"
  /// The OS rejected a native operation or target access.
  case accessDenied = "access-denied"
  /// A native operation failed for a reason described by its platform code.
  case nativeFailed = "native-failed"
  /// The execution deadline elapsed.
  case timedOut = "timed-out"
  /// All worker capacity is reserved.
  case busy
}
