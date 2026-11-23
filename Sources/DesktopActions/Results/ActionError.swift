import Foundation

/// A structured failure validated and normalized by the shared Rust model.
public struct ActionError: Codable, Error, Sendable, Equatable, Hashable, RustResultValue {
  struct Projection: Codable, Sendable, Hashable {
    let code: ActionErrorCode
    let diagnosticMessage: String
    var permission: ActionPermission? = nil
    var appleScriptErrorNumber: Int? = nil
    var nativeCode: Int64? = nil

    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.code == rhs.code && lhs.permission == rhs.permission
        && lhs.appleScriptErrorNumber == rhs.appleScriptErrorNumber
        && lhs.nativeCode == rhs.nativeCode
        && UTF8Text(lhs.diagnosticMessage) == UTF8Text(rhs.diagnosticMessage)
    }

    func hash(into hasher: inout Hasher) {
      hasher.combine(code)
      hasher.combine(permission)
      hasher.combine(appleScriptErrorNumber)
      hasher.combine(nativeCode)
      hasher.combine(UTF8Text(diagnosticMessage))
    }
  }
  static var resultKind: UInt32 { 0 }
  let projection: Projection
  init(projection: Projection) { self.projection = projection }

  /// The canonical failure category.
  public var code: ActionErrorCode { projection.code }
  /// Developer-facing text. Do not use diagnostics as localized product copy.
  public var diagnosticMessage: String { projection.diagnosticMessage }
  /// The macOS privacy permission associated with a permission denial.
  public var permission: ActionPermission? { projection.permission }
  /// The AppleScript number associated with an Automation denial or script failure.
  public var appleScriptErrorNumber: Int? { projection.appleScriptErrorNumber }
  /// The platform error number for a native access or execution failure.
  public var nativeCode: Int64? { projection.nativeCode }

  public init(from decoder: Decoder) throws {
    self = try RustResultJSON.decode(Self.self, from: decoder)
  }
  public func encode(to encoder: Encoder) throws { try RustResultJSON.encode(self, to: encoder) }

  /// Creates an invalid-input failure with shared diagnostic normalization.
  public static func invalidInput(_ message: String) -> Self {
    RustResultJSON.makeError(.init(code: .invalidInput, diagnosticMessage: message))
  }
  /// Creates a denial for a macOS privacy permission.
  public static func permissionDenied(_ permission: ActionPermission) -> Self {
    RustResultJSON.makeError(
      .init(code: .permissionDenied, diagnosticMessage: "", permission: permission))
  }
  /// Creates an Automation denial, retaining a reported AppleScript number.
  public static func automationPermissionDenied(appleScriptErrorNumber: Int? = nil) -> Self {
    RustResultJSON.makeError(
      .init(
        code: .permissionDenied, diagnosticMessage: "", permission: .automation,
        appleScriptErrorNumber: appleScriptErrorNumber))
  }
  /// Creates a missing-resource failure.
  public static func notFound(_ message: String) -> Self {
    RustResultJSON.makeError(.init(code: .notFound, diagnosticMessage: message))
  }
  /// Creates an open or launch failure.
  public static func openFailed(_ message: String) -> Self {
    RustResultJSON.makeError(.init(code: .openFailed, diagnosticMessage: message))
  }
  /// Creates a script failure, retaining its native AppleScript number.
  public static func appleScriptFailed(_ message: String, appleScriptErrorNumber: Int? = nil)
    -> Self
  {
    RustResultJSON.makeError(
      .init(
        code: .appleScriptFailed, diagnosticMessage: message,
        appleScriptErrorNumber: appleScriptErrorNumber))
  }
  /// Creates a screen-capture failure.
  public static func screenCaptureFailed(_ message: String) -> Self {
    RustResultJSON.makeError(.init(code: .screenCaptureFailed, diagnosticMessage: message))
  }
  /// Creates an unexpected SDK failure.
  public static func internalError(_ message: String) -> Self {
    RustResultJSON.makeError(.init(code: .internalError, diagnosticMessage: message))
  }
  /// Creates an unsupported-platform or unsupported-operation failure.
  public static func unsupportedAction(_ message: String = "") -> Self {
    RustResultJSON.makeError(.init(code: .unsupportedAction, diagnosticMessage: message))
  }
  /// Creates an OS access denial, separate from macOS privacy permissions.
  public static func accessDenied(_ message: String = "", nativeCode: Int64? = nil) -> Self {
    RustResultJSON.makeError(
      .init(code: .accessDenied, diagnosticMessage: message, nativeCode: nativeCode))
  }
  /// Creates a native operation failure with an optional platform error number.
  public static func nativeFailed(_ message: String = "", nativeCode: Int64? = nil) -> Self {
    RustResultJSON.makeError(
      .init(code: .nativeFailed, diagnosticMessage: message, nativeCode: nativeCode))
  }
  /// Creates a deadline failure.
  public static func timedOut(_ message: String = "") -> Self {
    RustResultJSON.makeError(.init(code: .timedOut, diagnosticMessage: message))
  }
  /// Creates a capacity failure.
  public static func busy(_ message: String = "") -> Self {
    RustResultJSON.makeError(.init(code: .busy, diagnosticMessage: message))
  }
}

extension ActionError: LocalizedError {
  public var errorDescription: String? { diagnosticMessage }
}
