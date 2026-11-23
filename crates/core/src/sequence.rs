//! Ordered requests, independently of native execution and host scheduling.

/// Host-selected behavior after a completed operation fails or is skipped.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum SequenceFailureBehavior {
    Stop = 0,
    Continue = 1,
}

/// The delivery from one bounded action runner, not acknowledgement of OS effects.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum SequenceActionResult {
    Success = 1,
    Failure = 2,
    Skipped = 3,
    Cancelled = 4,
    TimedOut = 5,
    Busy = 6,
}

/// Completion describes delivery of every request, not success of every effect.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum SequenceStatus {
    Running = 0,
    Completed = 1,
    Stopped = 2,
    Cancelled = 3,
    TimedOut = 4,
    Busy = 5,
}

/// Deterministic request ordering. The adapter retains action values and reports;
/// this reducer owns issuance, continuation, cancellation and aggregate success.
pub struct ActionSequence {
    count: usize,
    recorded: usize,
    outstanding: bool,
    failure_behavior: SequenceFailureBehavior,
    unsuccessful: bool,
    status: SequenceStatus,
}

impl ActionSequence {
    pub fn new(count: usize, failure_behavior: SequenceFailureBehavior) -> Self {
        Self {
            count,
            recorded: 0,
            outstanding: false,
            failure_behavior,
            unsuccessful: false,
            status: if count == 0 {
                SequenceStatus::Completed
            } else {
                SequenceStatus::Running
            },
        }
    }

    /// Claims a one-based request identity exactly once. No second request may
    /// start before the current delivery has been recorded.
    pub fn next_action(&mut self) -> Option<usize> {
        if self.status != SequenceStatus::Running || self.outstanding {
            return None;
        }
        self.outstanding = true;
        Some(self.recorded + 1)
    }

    /// Invalid, repeated or late identities leave the state unchanged. Timeout,
    /// cancellation and capacity rejection always stop: an unacknowledged native
    /// worker must not overlap a later request in an allegedly ordered sequence.
    pub fn record(&mut self, id: usize, result: SequenceActionResult) -> bool {
        if self.status != SequenceStatus::Running || !self.outstanding || id != self.recorded + 1 {
            return false;
        }
        self.outstanding = false;
        self.recorded += 1;
        self.unsuccessful |= result != SequenceActionResult::Success;
        self.status = match result {
            SequenceActionResult::Cancelled => SequenceStatus::Cancelled,
            SequenceActionResult::TimedOut => SequenceStatus::TimedOut,
            SequenceActionResult::Busy => SequenceStatus::Busy,
            SequenceActionResult::Failure | SequenceActionResult::Skipped
                if self.failure_behavior == SequenceFailureBehavior::Stop =>
            {
                SequenceStatus::Stopped
            }
            _ if self.recorded == self.count => SequenceStatus::Completed,
            _ => SequenceStatus::Running,
        };
        true
    }

    /// Stops issuing work between operations. Earlier results are retained by
    /// the adapter. A completed sequence cannot be retroactively cancelled.
    pub fn cancel(&mut self) {
        if self.status == SequenceStatus::Running {
            self.status = SequenceStatus::Cancelled;
        }
    }

    pub fn status(&self) -> SequenceStatus {
        self.status
    }
    pub fn recorded_count(&self) -> usize {
        self.recorded
    }
    pub fn all_actions_succeeded(&self) -> bool {
        self.status == SequenceStatus::Completed && !self.unsuccessful
    }
}
