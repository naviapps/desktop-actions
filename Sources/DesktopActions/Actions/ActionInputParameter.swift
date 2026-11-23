/// Metadata describing an action kind's host-supplied input parameter.
///
/// Hosts can use this when building labels, dynamic forms, schema exporters, or tool surfaces.
public struct ActionInputParameter: Equatable, Hashable, Sendable {
  /// The parameter name a host UI, schema exporter, or tool surface can expose.
  public let name: String
  /// A short description of the accepted input value.
  public let description: String
  /// A representative input value.
  public let exampleInput: ActionInput

  /// Creates metadata describing an action kind's host-supplied input parameter.
  ///
  /// Returns `nil` when a label is blank or the example carries an invalid value.
  public init?(name: String, description: String, exampleInput: ActionInput) {
    do {
      let raw = try Projection(
        name: name, description: description, exampleInput: .init(exampleInput))
      try self.init(projection: RustActionJSON.normalizeInputMetadata(raw, kind: .parameter))
    } catch {
      return nil
    }
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    UTF8Text(lhs.name) == UTF8Text(rhs.name)
      && UTF8Text(lhs.description) == UTF8Text(rhs.description)
      && lhs.exampleInput == rhs.exampleInput
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(UTF8Text(name))
    hasher.combine(UTF8Text(description))
    hasher.combine(exampleInput)
  }

  struct Projection: Codable {
    let name: String
    let description: String
    let exampleInput: ActionInput.Projection
  }

  init(projection: Projection) throws {
    name = projection.name
    description = projection.description
    exampleInput = try ActionInput(projection: projection.exampleInput)
  }

  func projection() throws -> Projection {
    try .init(name: name, description: description, exampleInput: .init(exampleInput))
  }
}

extension ActionInputParameter: Codable {
  /// Decodes parameter metadata through the Rust normalization boundary.
  public init(from decoder: Decoder) throws {
    try self.init(
      projection: RustActionJSON.decodeInputMetadata(
        Projection.self, from: decoder, kind: .parameter))
  }

  /// Encodes normalized parameter metadata.
  public func encode(to encoder: Encoder) throws {
    try projection().encode(to: encoder)
  }
}
