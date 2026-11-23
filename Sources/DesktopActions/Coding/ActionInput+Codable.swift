import Foundation
import WindowManagement

extension ActionInput {
  /// Decodes tagged input through the shared Rust normalization boundary.
  public init(from decoder: Decoder) throws {
    let raw = try ActionWireValue(from: decoder)
    let data: Data
    do { data = try RustActionJSON.normalizeInput(JSONEncoder().encode(raw)) } catch let error
      as ActionCodecError
    {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: decoder.codingPath,
          debugDescription: error.localizedDescription, underlyingError: error))
    }
    try self.init(projection: JSONDecoder().decode(Projection.self, from: data))
  }

  /// Encodes only normalized input; blank strings fail in Rust.
  public func encode(to encoder: Encoder) throws {
    let raw = try JSONEncoder().encode(Projection(self))
    let canonical: Data
    do { canonical = try RustActionJSON.normalizeInput(raw) } catch let error as ActionCodecError {
      throw EncodingError.invalidValue(
        self,
        .init(
          codingPath: encoder.codingPath,
          debugDescription: error.localizedDescription, underlyingError: error))
    }
    try JSONDecoder().decode(ActionWireValue.self, from: canonical).encode(to: encoder)
  }
  init(projection: Projection) throws {
    switch projection.shape {
    case .string: self = try .string(projection.value.decode(String.self))
    case .windowPlacement:
      self = try .windowPlacement(projection.value.decode(WindowPlacementRequest.self))
    case .windowMove: self = try .windowMove(projection.value.decode(WindowMoveRequest.self))
    case .none: throw ActionCodecError.invalidData("Input-free actions do not carry ActionInput.")
    }
  }

  struct Projection: Codable {
    let shape: ActionInputShape
    let value: ActionWireValue

    init(_ input: ActionInput) throws {
      shape = input.shape
      switch input {
      case .string(let text): value = .string(text)
      case .windowPlacement(let request): value = try .project(request)
      case .windowMove(let request): value = try .project(request)
      }
    }
  }
}
