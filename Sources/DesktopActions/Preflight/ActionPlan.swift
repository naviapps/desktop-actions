/// One instruction and its role in the ordered plan.
public struct ActionStep: Codable, Sendable, Equatable, Hashable {
  /// The native instruction interpreted by the plan's platform.
  public let method: ActionMethod
  /// Whether the instruction is a fallback for an earlier attempt.
  public let isFallback: Bool
  package var requiredPermissions: Set<ActionPermission> { method.requiredPermissions }
  package init(method: ActionMethod, isFallback: Bool = false) {
    self.method = method
    self.isFallback = isFallback
  }
}

/// The instructions and permission metadata selected by Rust for one native adapter.
public struct ActionPlan: Sendable, Equatable, Hashable {
  /// The adapter that can interpret this plan's instructions and native key codes.
  public let platform: ActionPlatform
  /// Ordered instructions. An empty array means there is no plan for this platform.
  public let steps: [ActionStep]
  private let metadata: RustPlanMetadata

  /// Whether the plan is nonempty and contains no invalid-input instructions.
  public var isExecutable: Bool { metadata.isExecutable }
  /// Requirements for the primary and fallback paths.
  public var permissionRequirements: ActionPermissionSet { metadata.permissions }
  /// First permission reasons in execution order.
  public var permissionHints: [ActionPermissionHint] { metadata.hints }

  package init(steps: [ActionStep], platform: ActionPlatform = .macOS) {
    self.init(
      platform: platform, steps: steps,
      metadata: RustActionPlanning.metadata(for: steps, on: platform))
  }

  init(platform: ActionPlatform, steps: [ActionStep], metadata: RustPlanMetadata) {
    self.platform = platform
    self.steps = steps
    self.metadata = metadata
  }
}
