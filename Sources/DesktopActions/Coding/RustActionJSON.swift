import CDesktopActions
import Foundation

/// Copies native bytes before releasing the owner; no foreign view escapes this boundary.
enum RustActionJSON {
  enum InputMetadataKind: UInt32 {
    case parameter = 0
    case descriptor = 1
  }

  static func takeCatalog() throws -> Data { try take(desktop_actions_catalog()) }
  static func evaluateTextInput(_ data: Data) throws -> Data {
    try data.withUnsafeBytes { bytes in
      try take(
        desktop_actions_text_input_evaluate(
          bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count))
    }
  }
  static func normalize(_ data: Data, envelope: Bool = false) throws -> Data {
    try data.withUnsafeBytes { bytes in
      try take(
        desktop_actions_action_normalize(
          bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, envelope ? 1 : 0))
    }
  }
  static func normalizeInput(_ data: Data) throws -> Data {
    try data.withUnsafeBytes { bytes in
      try take(
        desktop_actions_input_normalize(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count))
    }
  }
  static func normalizeInputMetadata<T: Codable>(_ value: T, kind: InputMetadataKind) throws -> T {
    try parseInputMetadata(T.self, data: JSONEncoder().encode(value), kind: kind)
  }

  static func decodeInputMetadata<T: Decodable>(
    _ type: T.Type, from decoder: Decoder, kind: InputMetadataKind
  ) throws -> T {
    do {
      let raw = try ActionWireValue(from: decoder)
      return try parseInputMetadata(type, data: JSONEncoder().encode(raw), kind: kind)
    } catch let error as ActionCodecError {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: decoder.codingPath,
          debugDescription: error.localizedDescription, underlyingError: error))
    }
  }

  private static func parseInputMetadata<T: Decodable>(
    _ type: T.Type, data: Data, kind: InputMetadataKind
  ) throws -> T {
    let canonical: Data = try data.withUnsafeBytes { bytes in
      try take(
        desktop_actions_input_metadata_normalize(
          bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, kind.rawValue))
    }
    return try JSONDecoder().decode(type, from: canonical)
  }
  static func plan(_ data: Data, for platform: ActionPlatform) throws -> Data {
    try data.withUnsafeBytes { bytes in
      try take(
        desktop_actions_action_plan(
          bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, platform.nativeValue))
    }
  }
  static func kindPlan(_ identifier: String, for platform: ActionPlatform) throws -> Data {
    try Data(identifier.utf8).withUnsafeBytes { bytes in
      try take(
        desktop_actions_action_kind_plan(
          bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, platform.nativeValue))
    }
  }
  static func planMetadata(_ data: Data, for platform: ActionPlatform) throws -> Data {
    try data.withUnsafeBytes { bytes in
      try take(
        desktop_actions_plan_metadata(
          bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, platform.nativeValue))
    }
  }
  static func take(_ owner: OpaquePointer?) throws -> Data {
    guard let owner else { throw ActionCodecError.invalidData("Native JSON owner is unavailable.") }
    defer { desktop_actions_json_destroy(owner) }
    guard desktop_actions_abi_version() == DESKTOP_ACTIONS_ABI_VERSION else {
      throw ActionCodecError.invalidData("Unsupported native DesktopActions ABI.")
    }
    let view = desktop_actions_json_view(owner)
    guard let pointer = view.data else {
      throw ActionCodecError.invalidData("Native JSON bytes are unavailable.")
    }
    let data = Data(bytes: pointer, count: view.length)
    guard view.code == 0 else {
      if view.code == 2, view.has_version != 0, let version = Int(exactly: view.version) {
        throw ActionCodecError.unsupportedVersion(version)
      }
      throw ActionCodecError.invalidData(String(decoding: data, as: UTF8.self))
    }
    return data
  }
}

extension ActionPlatform {
  fileprivate var nativeValue: UInt32 {
    switch self {
    case .macOS: 0
    case .windows: 1
    }
  }
}
