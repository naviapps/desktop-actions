import Foundation

/// Strict original-byte JSON codecs for execution reports. Rust validates duplicates,
/// associated fields, durations and attempt/final-result consistency before Swift projection.
public enum ActionResultCodec {
  /// Decodes an existing structured error; blank diagnostics are rejected.
  public static func decodeError(_ data: Data) throws -> ActionError {
    try RustResultJSON.decode(ActionError.self, data: data)
  }
  /// Decodes a single operation result.
  public static func decodeResult(_ data: Data) throws -> ActionResult {
    try RustResultJSON.decode(ActionResult.self, data: data)
  }
  /// Decodes a measured execution attempt.
  public static func decodeAttempt(_ data: Data) throws -> ActionAttempt {
    try RustResultJSON.decode(ActionAttempt.self, data: data)
  }
  /// Decodes a nonempty execution report with a consistent final result.
  public static func decodeExecutionReport(_ data: Data) throws -> ActionExecutionReport {
    try RustResultJSON.decode(ActionExecutionReport.self, data: data)
  }
  /// Encodes a canonical structured error.
  public static func encode(_ value: ActionError) throws -> Data {
    try RustResultJSON.encode(value)
  }
  /// Encodes a canonical operation result.
  public static func encode(_ value: ActionResult) throws -> Data {
    try RustResultJSON.encode(value)
  }
  /// Encodes a canonical measured attempt.
  public static func encode(_ value: ActionAttempt) throws -> Data {
    try RustResultJSON.encode(value)
  }
  /// Encodes a canonical execution report.
  public static func encode(_ value: ActionExecutionReport) throws -> Data {
    try RustResultJSON.encode(value)
  }
}
