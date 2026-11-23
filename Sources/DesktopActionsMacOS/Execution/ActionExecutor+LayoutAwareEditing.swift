import ApplicationServices
import DesktopActions

struct LayoutAwareEditingAction: Sendable {
  let letter: EditingKeyResolver.Letter
  let stroke: ActionKeyStroke

  init?(_ kind: ActionKind) {
    guard let chord = ActionPreflight.macOSEditingChord(for: kind),
      let letter = EditingKeyResolver.Letter(rawValue: chord.letter),
      [.command, [.command, .shift]].contains(chord.stroke.modifiers)
    else { return nil }
    self.letter = letter
    stroke = chord.stroke
  }

  var shift: Bool { stroke.modifiers.contains(.shift) }

  func matches(_ plan: ActionPlan) -> Bool {
    plan.steps == [.init(method: .keyEvent(stroke))]
      && plan.permissionRequirements == .init(primary: [.accessibility], fallback: [])
  }
}

extension ActionExecutor {
  func executeLayoutAwareEditing(
    _ action: LayoutAwareEditingAction, beforeStep: (@Sendable () async -> Bool)?
  ) async throws(CancellationError) -> ActionResult {
    let outcome = try await LayoutAwareEditingDispatch.perform(
      action, resolver: dependencies.editingKeyResolver, poster: dependencies.keyEventPoster,
      beforeStep: beforeStep)
    try checkCancellation()
    switch outcome {
    case .posted:
      return .success
    case .unavailableLayout:
      return failureResult(
        .unsupportedAction(
          "The current keyboard layout cannot safely perform this editing action."),
        logLevel: .warning)
    case .postingFailed:
      return internalErrorResult("Failed to post key stroke event")
    }
  }
}

private enum LayoutAwareEditingDispatch: Sendable {
  case posted
  case unavailableLayout
  case postingFailed

  @MainActor
  static func perform(
    _ action: LayoutAwareEditingAction, resolver: EditingKeyResolver,
    poster: any KeyEventPosting, beforeStep: (@Sendable () async -> Bool)?
  ) async throws(CancellationError) -> Self {
    guard !Task.isCancelled else { throw CancellationError() }
    if let beforeStep, !(await beforeStep()) { throw CancellationError() }
    guard !Task.isCancelled else { throw CancellationError() }

    // All remaining work is synchronous on the MainActor. The live poster rechecks
    // the layout inside the existing pair lock just before emitting key down.
    guard let match = resolver.resolve(action.letter, shift: action.shift) else {
      return .unavailableLayout
    }
    guard !Task.isCancelled else { throw CancellationError() }
    let flags: CGEventFlags = action.shift ? [.maskCommand, .maskShift] : [.maskCommand]
    var staleLayout = false
    let posted = poster.postKeyStroke(
      virtualKey: match.virtualKey, flags: flags,
      beforePosting: {
        let current = resolver.isCurrent(match)
        staleLayout = !current
        return current
      })
    guard !Task.isCancelled else { throw CancellationError() }
    if staleLayout { return .unavailableLayout }
    return posted ? .posted : .postingFailed
  }
}
