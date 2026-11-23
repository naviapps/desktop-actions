/// The final report of an execution, with Rust-validated ordered attempts.
public struct ActionExecutionReport: Codable, Sendable, Equatable, Hashable, RustResultValue {
  /// The ordered native execution records.
  public let attempts: [ActionAttempt]
  /// The result derived from the last attempt by Rust.
  public let finalResult: ActionResult

  /// Records a host-supplied result without inventing permissions or elapsed time.
  public init(result: ActionResult) {
    self.init(attempts: [.init(requiredPermissions: [], isFallback: false, result: result)])
  }
  package init(attempts: [ActionAttempt]) { self = RustResultJSON.makeExecutionReport(attempts) }
  /// The last successful attempt, if any.
  public var successfulAttempt: ActionAttempt? { attempts.last { $0.result == .success } }
  /// Whether any fallback path was attempted.
  public var didAttemptFallback: Bool { attempts.contains { $0.isFallback } }

  struct Projection: Codable {
    let finalResult: ActionResult.Projection
    let attempts: [ActionAttempt.Projection]
  }
  static var resultKind: UInt32 { 3 }
  var projection: Projection {
    .init(finalResult: finalResult.projection, attempts: attempts.map(\.projection))
  }
  init(projection: Projection) {
    finalResult = .init(projection: projection.finalResult)
    attempts = projection.attempts.map(ActionAttempt.init(projection:))
  }
  public init(from decoder: Decoder) throws {
    self = try RustResultJSON.decode(Self.self, from: decoder)
  }
  public func encode(to encoder: Encoder) throws { try RustResultJSON.encode(self, to: encoder) }
}
