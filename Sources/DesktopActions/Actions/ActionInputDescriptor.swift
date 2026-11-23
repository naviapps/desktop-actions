/// Metadata describing the host-supplied input required by an action kind.
///
/// Use this when building action pickers, dynamic forms, or tool surfaces before an executable
/// ``ActionRequest`` exists.
public struct ActionInputDescriptor: Equatable, Hashable, Sendable {
  /// Input-free descriptor used by action kinds that do not require host-supplied values.
  public static let none = ActionInputDescriptor(canonicalShape: .none, parameter: nil)

  /// The structural shape of the required input.
  public let shape: ActionInputShape
  /// Parameter metadata for the required input.
  ///
  /// This is present when ``requiresInput`` is `true` and absent for ``none``.
  public let parameter: ActionInputParameter?

  /// Whether this descriptor requires a host-supplied ``ActionInput``.
  ///
  /// This is derived from ``shape`` and is not encoded as separate metadata.
  public var requiresInput: Bool {
    shape != .none
  }

  /// A representative input value for this descriptor, when input is required.
  public var exampleInput: ActionInput? {
    parameter?.exampleInput
  }

  /// Creates an input descriptor for an action kind.
  ///
  /// Returns `nil` when required-input metadata is missing, the example has another shape,
  /// or an input-free descriptor declares a parameter.
  public init?(shape: ActionInputShape, parameter: ActionInputParameter? = nil) {
    do {
      let raw = try Projection(shape: shape, parameter: parameter?.projection())
      try self.init(projection: RustActionJSON.normalizeInputMetadata(raw, kind: .descriptor))
    } catch {
      return nil
    }
  }

  private init(canonicalShape shape: ActionInputShape, parameter: ActionInputParameter?) {
    self.shape = shape
    self.parameter = parameter
  }

  private struct Projection: Codable {
    let shape: ActionInputShape
    let parameter: ActionInputParameter.Projection?
  }

  private init(projection: Projection) throws {
    try self.init(
      canonicalShape: projection.shape,
      parameter: projection.parameter.map(ActionInputParameter.init(projection:)))
  }
}

extension ActionInputDescriptor: Codable {
  /// Decodes and validates descriptor metadata through Rust.
  public init(from decoder: Decoder) throws {
    try self.init(
      projection: RustActionJSON.decodeInputMetadata(
        Projection.self, from: decoder, kind: .descriptor))
  }

  /// Encodes normalized descriptor metadata.
  public func encode(to encoder: Encoder) throws {
    try Projection(shape: shape, parameter: parameter?.projection()).encode(to: encoder)
  }
}
