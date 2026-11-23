import DesktopActions

/// Executes actions using live macOS integrations.
public actor ActionExecutor {
  let configuration: ActionExecutorConfiguration
  let dependencies: ActionExecutorDependencies

  /// Creates an executor with live dependencies.
  ///
  /// - Parameter configuration: Host-provided execution hooks and diagnostics.
  public init(configuration: ActionExecutorConfiguration = .init()) {
    self.init(configuration: configuration, dependencies: .live)
  }

  /// Executes an action.
  ///
  /// - Parameter action: The action to execute.
  /// - Returns: The ordered execution outcome.
  /// - Throws: `CancellationError` when the calling task is cancelled.
  public func execute(_ action: ActionRequest) async throws(CancellationError)
    -> ActionExecutionReport
  {
    try await executeAction(action, beforeStep: nil)
  }

  /// Executes an action with a host authorization check around permission preparation and dispatch.
  ///
  /// The check runs before Accessibility and Automation hooks and any System Events launch,
  /// and again before each step's dispatch, even if its prerequisites failed. If Screen Recording
  /// access is denied, the check runs before the host's recovery hook and again when it returns.
  /// The check may run multiple times per step. Returning false throws `CancellationError` and
  /// abandons the plan. It does not hold focus through asynchronous work or undo a started request.
  public func execute(
    _ action: ActionRequest,
    beforeStep: @escaping @Sendable () async -> Bool
  ) async throws(CancellationError) -> ActionExecutionReport {
    try await executeAction(action, beforeStep: beforeStep)
  }

  package init(
    configuration: ActionExecutorConfiguration = .init(),
    dependencies: ActionExecutorDependencies
  ) {
    self.configuration = configuration
    self.dependencies = dependencies
  }

  package func execute(plan: ActionPlan) async throws(CancellationError) -> ActionExecutionReport {
    try checkCancellation()
    guard plan.platform == .macOS else {
      return .init(
        result: failureResult(
          .unsupportedAction("Cannot execute an action plan for another platform."),
          logLevel: .warning))
    }
    return try await execute(context: .init(plan: plan))
  }

  private func executeAction(
    _ action: ActionRequest, beforeStep: (@Sendable () async -> Bool)?
  ) async throws(CancellationError) -> ActionExecutionReport {
    try checkCancellation()
    guard action.kind.category == .editing else {
      return try await execute(context: .init(action: action), beforeStep: beforeStep)
    }
    let plan = ActionPreflight.plan(for: action)
    guard let editing = LayoutAwareEditingAction(action.kind), editing.matches(plan) else {
      try checkCancellation()
      return .init(
        result: failureResult(
          .unsupportedAction("Unexpected native plan for the dedicated editing action."),
          logLevel: .warning))
    }
    return try await execute(context: .init(plan: plan), beforeStep: beforeStep, editing: editing)
  }

  private func execute(
    context: ActionExecutionContext,
    beforeStep: (@Sendable () async -> Bool)? = nil,
    editing: LayoutAwareEditingAction? = nil
  ) async throws(CancellationError) -> ActionExecutionReport {
    try checkCancellation()
    let clock = ContinuousClock()
    while let next = context.next() {
      try checkCancellation()
      let step = next.step
      let start = clock.now
      let failure = try await prerequisiteFailure(for: step.method, beforeStep: beforeStep)
      let result: ActionResult
      if let editing, failure == nil {
        result = try await executeLayoutAwareEditing(editing, beforeStep: beforeStep)
      } else {
        try await checkBeforeStep(beforeStep)
        if let failure {
          if case .failure(let error) = failure, error.permission == .screenRecording {
            await configuration.permissions.onScreenRecordingRequired()
            try await checkBeforeStep(beforeStep)
          }
          result = failure
        } else {
          result = try await execute(step.method)
        }
      }
      try checkCancellation()
      context.record(result, id: next.id, duration: clock.now - start)
    }
    let report = context.report()
    if report.notifyAutomationDenied {
      try checkCancellation()
      await configuration.permissions.onAutomationDenied(report.automationErrorNumber)
      try checkCancellation()
    }
    return report.outcome
  }

  private func execute(_ method: ActionMethod) async throws(CancellationError) -> ActionResult {
    try checkCancellation()
    switch method {
    case .invalidInput(let message):
      return invalidInputResult(message)
    case .keyEvent(let event):
      return try executeKeyEvent(event)
    case .systemKey(let code):
      let posted = dependencies.keyEventPoster.postSystemKey(code)
      try checkCancellation()
      return posted ? .success : internalErrorResult("Failed to post system key event")
    case .keyEventFromKeyboardShortcut(let shortcut):
      return try executeKeyboardShortcut(shortcut)
    case .appleScript(let source, _, _):
      return try await runAppleScript(source)
    case .openURL(let value):
      return try await executeOpenURL(value)
    case .openFolder(let value):
      return try await executeOpenFolder(value)
    case .launchApplication(let value):
      return try await executeLaunchApplication(value)
    case .runShortcut(let value):
      return try await executeRunShortcut(value)
    case .hideFrontmostApplication:
      return try await executeHideFrontmostApplication()
    case .terminateFrontmostApplication:
      return try await executeTerminateFrontmostApplication()
    case .lockSession, .toggleDesktop:
      return failureResult(
        .unsupportedAction("This instruction requires Windows."), logLevel: .warning)
    case .screenCapture(let arguments):
      return try await executeScreenCapture(arguments: arguments)
    case .windowing(let execution):
      return try await executeWindowing(execution)
    }
  }

  private func prerequisiteFailure(
    for method: ActionMethod, beforeStep: (@Sendable () async -> Bool)?
  ) async throws(CancellationError) -> ActionResult? {
    for permission in method.requiredPermissions.canonicalCodableOrder {
      try checkCancellation()
      let isReady: Bool
      switch permission {
      case .accessibility:
        try await checkBeforeStep(beforeStep)
        isReady = await configuration.permissions.ensureAccessibility()
      case .automation:
        try await checkBeforeStep(beforeStep)
        // The host's Automation check can require a running Apple Events target.
        if case .appleScript(_, true, _) = method {
          let running = await dependencies.systemEventsLauncher.ensureRunning()
          try await checkBeforeStep(beforeStep)
          guard running else { return internalErrorResult("System Events is not running") }
        }
        isReady = await configuration.permissions.ensureAutomation()
      case .screenRecording:
        isReady = dependencies.screenCaptureAccessChecker.hasAccess()
      }

      try checkCancellation()
      guard !isReady else { continue }
      return permissionDeniedResult(permission)
    }

    return nil
  }

  private func checkBeforeStep(_ beforeStep: (@Sendable () async -> Bool)?)
    async throws(CancellationError)
  {
    try checkCancellation()
    if let beforeStep {
      guard await beforeStep() else { throw CancellationError() }
      try checkCancellation()
    }
  }

  func checkCancellation() throws(CancellationError) {
    if Task.isCancelled { throw CancellationError() }
  }
}
