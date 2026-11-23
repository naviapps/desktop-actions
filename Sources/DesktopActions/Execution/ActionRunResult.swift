/// A terminal delivery. Cancellation/timeout does not prove that native work stopped.
public enum ActionRunResult: Sendable, Equatable {
  /// The worker completed before its deadline.
  case completed(ActionExecutionReport)
  /// Cancellation won terminal delivery.
  case cancelled
  /// The deadline elapsed before terminal delivery.
  case timedOut
  /// Actual workers already occupy the configured capacity.
  case busy
}
