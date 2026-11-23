import Foundation

private struct ActionEnvelope: Sendable {
  let action: ActionRequest
}

extension ActionEnvelope: Codable {
  private enum CodingKeys: String, CodingKey {
    case version
    case action
  }

  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownKeys(
      allowed: [CodingKeys.version, .action],
      debugName: "ActionEnvelope"
    )
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    guard version == ActionCodec.currentVersion else {
      throw ActionCodecError.unsupportedVersion(version)
    }
    self.action = try container.decode(ActionRequest.self, forKey: .action)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(ActionCodec.currentVersion, forKey: .version)
    try container.encode(action, forKey: .action)
  }
}

/// Encodes and decodes versioned JSON action envelopes.
public enum ActionCodec {
  /// The JSON envelope version emitted by this codec.
  public static let currentVersion = 1

  /// Encodes an action into a versioned JSON envelope.
  ///
  /// - Parameters:
  ///   - action: The action to encode.
  ///   - encoder: The JSON encoder used for the envelope.
  /// - Returns: The encoded JSON envelope.
  /// - Throws: Any encoding error produced by the encoder.
  public static func encode(
    _ action: ActionRequest,
    encoder: JSONEncoder = JSONEncoder()
  ) throws -> Data {
    try encoder.encode(ActionEnvelope(action: action))
  }

  /// Validates original JSON bytes in Rust and decodes a versioned action envelope.
  ///
  /// - Parameters:
  ///   - data: The encoded JSON envelope.
  ///   - decoder: The JSON decoder used for the envelope.
  /// - Returns: The decoded action.
  /// - Throws: `ActionCodecError` when native validation fails, or a decoding error from the decoder.
  public static func decode(
    _ data: Data,
    decoder: JSONDecoder = JSONDecoder()
  ) throws -> ActionRequest {
    let canonical = try RustActionJSON.normalize(data, envelope: true)
    let envelope = try decoder.decode(ActionEnvelope.self, from: canonical)
    return envelope.action
  }

  /// Decodes the original JSON bytes of a bare action using the shared Rust codec.
  public static func decodeRequest(_ data: Data) throws -> ActionRequest {
    let canonical = try RustActionJSON.normalize(data)
    return try ActionRequest(
      projecting: JSONDecoder().decode(ActionRequest.Projection.self, from: canonical))
  }

  /// Decodes the original JSON bytes of a standalone tagged input using the shared Rust codec.
  public static func decodeInput(_ data: Data) throws -> ActionInput {
    let canonical = try RustActionJSON.normalizeInput(data)
    return try ActionInput(
      projection: JSONDecoder().decode(ActionInput.Projection.self, from: canonical))
  }
}
