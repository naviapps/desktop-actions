extension ActionPreflight {
  /// Returns permission hints for an action.
  ///
  /// - Parameter action: The executable action to inspect.
  /// - Returns: Permission hints ordered by execution path.
  public static func permissionHints(for action: ActionRequest) -> [ActionPermissionHint] {
    permissionHints(for: plan(for: action))
  }

  /// Returns input-independent permission hints for an action kind.
  ///
  /// - Parameter kind: The action kind to inspect before host input is available.
  /// - Returns: Input-independent permission hints ordered by execution path.
  public static func permissionHints(forKind kind: ActionKind) -> [ActionPermissionHint] {
    inspectKind(kind).permissionHints
  }

  static func permissionHints(for plan: ActionPlan) -> [ActionPermissionHint] {
    plan.permissionHints
  }
}
