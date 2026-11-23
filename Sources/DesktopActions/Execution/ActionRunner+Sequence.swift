import CDesktopActions

extension ActionRunner {
  /// Runs requests in order with shared capacity/deadline arbitration. Timeout,
  /// cancellation and capacity rejection always stop the sequence: a native
  /// worker may still be acknowledging cancellation. Completed failures/skips
  /// follow explicit host policy. Empty input completes without invoking work.
  public func runSequence(
    _ actions: [ActionRequest],
    failureBehavior: ActionSequenceFailureBehavior,
    exemptFromTimeout: @Sendable (ActionRequest) -> Bool = { _ in false },
    operation:
      @escaping @Sendable (ActionRequest) async throws(CancellationError) -> ActionExecutionReport
  ) async -> ActionSequenceReport {
    let sequence = SequenceState(count: actions.count, failureBehavior: failureBehavior)
    var results: [ActionRunResult] = []
    while true {
      if Task.isCancelled { desktop_actions_sequence_cancel(sequence.handle) }
      let id = desktop_actions_sequence_next(sequence.handle)
      guard id != 0 else { break }
      let action = actions[id - 1]
      let result = await run(
        action, exemptFromTimeout: exemptFromTimeout(action), operation: operation)
      precondition(desktop_actions_sequence_record(sequence.handle, id, result.sequenceCode) == 0)
      results.append(result)
    }
    let summary = desktop_actions_sequence_summary(sequence.handle)
    guard let status = ActionSequenceStatus(rawValue: summary.status),
      summary.recorded_count == results.count
    else { preconditionFailure("Native action sequence and Swift projection differ") }
    return .init(
      status: status, results: results,
      allActionsSucceeded: summary.all_actions_succeeded != 0)
  }
}

private final class SequenceState {
  let handle: OpaquePointer
  init(count: Int, failureBehavior: ActionSequenceFailureBehavior) {
    precondition(
      desktop_actions_abi_version() == DESKTOP_ACTIONS_ABI_VERSION,
      "Unsupported native DesktopActions ABI")
    handle = desktop_actions_sequence_create(count, failureBehavior.rawValue)!
  }
  deinit { desktop_actions_sequence_destroy(handle) }
}

extension ActionRunResult {
  fileprivate var sequenceCode: UInt32 {
    switch self {
    case .completed(let report):
      switch report.finalResult {
      case .success: 1
      case .failure: 2
      case .skipped: 3
      }
    case .cancelled: 4
    case .timedOut: 5
    case .busy: 6
    }
  }
}
