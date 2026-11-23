/// A recorded attempt to execute an action.
public struct ActionAttempt: Codable, Sendable, Equatable, Hashable, RustResultValue {
  /// Permissions required by this attempt.
  public let requiredPermissions: Set<ActionPermission>
  /// Whether this attempt used a fallback execution path.
  public let isFallback: Bool
  /// The result produced by the attempt.
  public let result: ActionResult
  /// The elapsed time in the wire's floating-point seconds, when measured.
  public let durationSeconds: Double?
  /// The elapsed time rounded to the closest attosecond for Swift time APIs.
  public var duration: Duration? {
    // A locally created attempt can hold a measurement that Rust rejects at encode time.
    guard let durationSeconds, durationSeconds < Double(Int64.max) else { return nil }
    return .seconds(durationSeconds)
  }

  package init(
    requiredPermissions: Set<ActionPermission>,
    isFallback: Bool,
    result: ActionResult,
    duration: Duration? = nil
  ) {
    self.requiredPermissions = requiredPermissions
    self.isFallback = isFallback
    self.result = result
    durationSeconds = duration.map(Self.wireSeconds)
  }

  static func wireSeconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds)
      + Double(components.attoseconds) / 1_000_000_000_000_000_000
  }
}

extension ActionAttempt {
  struct Projection: Codable {
    let requiredPermissions: [ActionPermission]
    let isFallback: Bool
    let result: ActionResult.Projection
    let durationSeconds: Double?
  }
  static var resultKind: UInt32 { 2 }
  var projection: Projection {
    .init(
      requiredPermissions: Array(requiredPermissions), isFallback: isFallback,
      result: result.projection, durationSeconds: durationSeconds)
  }
  init(projection: Projection) {
    requiredPermissions = Set(projection.requiredPermissions)
    isFallback = projection.isFallback
    result = .init(projection: projection.result)
    durationSeconds = projection.durationSeconds
  }
  public init(from decoder: Decoder) throws {
    self = try RustResultJSON.decode(Self.self, from: decoder)
  }
  public func encode(to encoder: Encoder) throws { try RustResultJSON.encode(self, to: encoder) }
}
