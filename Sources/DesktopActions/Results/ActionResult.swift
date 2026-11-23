/// The result of one action attempt or a whole action.
public enum ActionResult: Codable, Sendable, Equatable, Hashable, RustResultValue {
  /// The operation completed successfully.
  case success
  /// No eligible target was available.
  case skipped(ActionSkipReason)
  /// The operation failed with a structured error.
  case failure(ActionError)

  struct Projection: Codable {
    enum Status: String, Codable { case success, skipped, failure }
    let status: Status
    var skipReason: ActionSkipReason? = nil
    var error: ActionError.Projection? = nil
  }
  static var resultKind: UInt32 { 1 }
  var projection: Projection {
    switch self {
    case .success: .init(status: .success)
    case .skipped(let reason): .init(status: .skipped, skipReason: reason)
    case .failure(let error): .init(status: .failure, error: error.projection)
    }
  }
  init(projection: Projection) {
    switch projection.status {
    case .success: self = .success
    case .skipped: self = .skipped(projection.skipReason!)
    case .failure: self = .failure(.init(projection: projection.error!))
    }
  }
  public init(from decoder: Decoder) throws {
    self = try RustResultJSON.decode(Self.self, from: decoder)
  }
  public func encode(to encoder: Encoder) throws { try RustResultJSON.encode(self, to: encoder) }
}
