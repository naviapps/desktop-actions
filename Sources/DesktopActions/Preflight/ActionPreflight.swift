/// Availability and permission guidance for a kind before its input is known.
public struct ActionKindPreflight: Sendable, Equatable, Hashable {
  public let platform: ActionPlatform
  public let isExecutable: Bool
  public let permissionRequirements: ActionPermissionSet
  public let permissionHints: [ActionPermissionHint]

  init(plan: ActionPlan) {
    platform = plan.platform
    isExecutable = plan.isExecutable
    permissionRequirements = plan.permissionRequirements
    permissionHints = plan.permissionHints
  }
}

/// Builds permission requirements and permission hints for actions.
public enum ActionPreflight {
  /// Whether Rust can plan this input for macOS without an invalid-input instruction.
  /// This does not query permissions, installed targets or live OS state, and executes no effects.
  public static func isExecutable(_ action: ActionRequest) -> Bool {
    isExecutable(action, on: .macOS)
  }

  /// Whether Rust can plan the request for the given platform without an invalid-input instruction.
  public static func isExecutable(_ action: ActionRequest, on platform: ActionPlatform) -> Bool {
    action.plan(for: platform).isExecutable
  }

  package static func plan(for action: ActionRequest) -> ActionPlan {
    action.plan(for: .macOS)
  }

  /// Inspects availability and permission hints before collecting input.
  /// Plan an actual request to validate its input and inspect instructions.
  public static func inspectKind(_ kind: ActionKind, on platform: ActionPlatform = .macOS)
    -> ActionKindPreflight
  {
    .init(plan: RustActionPlanning.plan(forKind: kind, on: platform))
  }

  /// Returns the aggregate permission requirements for an action.
  ///
  /// - Parameter action: The executable action to inspect.
  /// - Returns: The permissions required by the action's primary and fallback paths.
  public static func permissions(for action: ActionRequest) -> ActionPermissionSet {
    plan(for: action).permissionRequirements
  }

  /// Returns the input-independent permission requirements for an action kind.
  ///
  /// - Parameter kind: The action kind to inspect before host input is available.
  /// - Returns: The input-independent permissions required by the action kind.
  public static func permissions(forKind kind: ActionKind) -> ActionPermissionSet {
    inspectKind(kind).permissionRequirements
  }
}
