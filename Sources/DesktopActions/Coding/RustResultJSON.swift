import CDesktopActions
import Foundation

/// Language projections contain no validation policy; all result contracts belong to Rust.
protocol RustResultValue {
  associatedtype Projection: Codable
  static var resultKind: UInt32 { get }
  var projection: Projection { get }
  init(projection: Projection)
}

enum RustResultJSON {
  static func normalize(_ data: Data, kind: UInt32) throws -> Data {
    try data.withUnsafeBytes { bytes in
      try RustActionJSON.take(
        desktop_actions_result_normalize(
          bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, kind))
    }
  }
  static func decode<T: RustResultValue>(_: T.Type, data: Data) throws -> T {
    let canonical = try normalize(data, kind: T.resultKind)
    return try T(projection: JSONDecoder().decode(T.Projection.self, from: canonical))
  }
  static func decode<T: RustResultValue>(_ type: T.Type, from decoder: Decoder) throws -> T {
    do {
      return try decode(type, data: JSONEncoder().encode(ActionWireValue(from: decoder)))
    } catch let error as ActionCodecError {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: decoder.codingPath, debugDescription: error.localizedDescription,
          underlyingError: error))
    }
  }
  static func encode<T: RustResultValue>(_ value: T) throws -> Data {
    try normalize(JSONEncoder().encode(value.projection), kind: T.resultKind)
  }
  static func encode<T: RustResultValue>(_ value: T, to encoder: Encoder) throws {
    do {
      try JSONDecoder().decode(ActionWireValue.self, from: encode(value)).encode(to: encoder)
    } catch let error as ActionCodecError {
      throw EncodingError.invalidValue(
        value,
        .init(
          codingPath: encoder.codingPath, debugDescription: error.localizedDescription,
          underlyingError: error))
    }
  }
  static func makeError(_ spec: ActionError.Projection) -> ActionError {
    do {
      let data = try JSONEncoder().encode(spec)
      let canonical = try data.withUnsafeBytes { bytes in
        try RustActionJSON.take(
          desktop_actions_error_create(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count))
      }
      return try ActionError(
        projection: JSONDecoder().decode(ActionError.Projection.self, from: canonical))
    } catch { preconditionFailure("Native error factory and Swift projection differ: \(error)") }
  }
  static func makeExecutionReport(_ attempts: [ActionAttempt]) -> ActionExecutionReport {
    do {
      let data = try JSONEncoder().encode(attempts.map(\.projection))
      let canonical = try data.withUnsafeBytes { bytes in
        try RustActionJSON.take(
          desktop_actions_execution_report_create(
            bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count))
      }
      return try ActionExecutionReport(
        projection: JSONDecoder().decode(ActionExecutionReport.Projection.self, from: canonical))
    } catch { preconditionFailure("Native outcome factory and Swift projection differ: \(error)") }
  }
}
