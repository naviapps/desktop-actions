/// Host-selected continuation after a completed operation fails or is skipped.
public enum ActionSequenceFailureBehavior: UInt32, Sendable {
  /// Stops after the first completed failure or skipped operation.
  case stop = 0
  /// Retains the failure or skipped result and attempts the next request.
  case `continue` = 1
}

/// Why an ordered request sequence stopped delivering results.
public enum ActionSequenceStatus: UInt32, Sendable {
  /// Every request delivered a result; inspect allActionsSucceeded for effect success.
  case completed = 1
  /// Host policy stopped after a completed failure or skipped operation.
  case stopped = 2
  /// Cancellation stopped further request issuance.
  case cancelled = 3
  /// A deadline elapsed; native acknowledgement may still be pending.
  case timedOut = 4
  /// The runner had no free native worker capacity.
  case busy = 5
}

/// Immutable ordered deliveries. Cancellation or timeout does not undo an OS effect.
public struct ActionSequenceReport: Sendable, Equatable {
  /// The Rust-selected terminal sequence status.
  public let status: ActionSequenceStatus
  /// Ordered deliveries for requests reached before termination.
  public let results: [ActionRunResult]
  /// Rust-derived success: every request completed successfully (including an empty sequence).
  public let allActionsSucceeded: Bool
}
