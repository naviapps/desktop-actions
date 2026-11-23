use std::collections::BTreeMap;
/// Monotonically allocated execution identity; active identities are never reused.
pub type ExecutionId = u64;
/// Terminal delivery chosen exactly once, independently of native task acknowledgement.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum Terminal {
    Completed = 1,
    Cancelled = 2,
    TimedOut = 3,
}
struct Entry {
    deadline: Option<u64>,
    terminal: Option<Terminal>,
}
/// Serial host-clock reducer. A cancelled/timed-out native worker continues to
/// hold capacity until it acknowledges completion; uncooperative tasks cannot
/// make the advertised concurrency bound silently grow without limit.
pub struct ExecutionPool {
    maximum: usize,
    next: u64,
    timeout: u64,
    now: u64,
    closed: bool,
    active: BTreeMap<ExecutionId, Entry>,
}
impl ExecutionPool {
    /// Configure capacity and a default timeout. Hosts may exempt interactive selections.
    pub fn new(maximum: usize, timeout_ns: u64) -> Option<Self> {
        if maximum == 0 || timeout_ns == 0 {
            return None;
        }
        Some(Self {
            maximum,
            next: 0,
            timeout: timeout_ns,
            now: 0,
            closed: false,
            active: BTreeMap::new(),
        })
    }
    /// Reserve capacity, returning none if closed or full. Time regressions are clamped.
    pub fn reserve(&mut self, now: u64, interactive: bool) -> Option<ExecutionId> {
        self.now = self.now.max(now);
        if self.closed || self.active.len() >= self.maximum {
            return None;
        }
        self.next = self.next.checked_add(1)?;
        self.active.insert(
            self.next,
            Entry {
                deadline: if interactive {
                    None
                } else {
                    Some(self.now.saturating_add(self.timeout))
                },
                terminal: None,
            },
        );
        Some(self.next)
    }
    /// Return an absolute deadline without advancing state or delivering timeout.
    pub fn deadline(&self, id: ExecutionId) -> Option<u64> {
        self.active
            .get(&id)
            .filter(|e| e.terminal.is_none())
            .and_then(|e| e.deadline)
    }
    /// Claim one terminal callback. Capacity remains reserved until acknowledge.
    fn settle(&mut self, id: ExecutionId, terminal: Terminal) -> bool {
        let Some(entry) = self.active.get_mut(&id) else {
            return false;
        };
        if entry.terminal.is_some() {
            false
        } else {
            entry.terminal = Some(terminal);
            true
        }
    }
    /// Claim cancellation, or timeout when the deadline already elapsed. Capacity
    /// remains held until the actual worker acknowledges completion.
    pub fn cancel(&mut self, id: ExecutionId, now: u64) -> Option<Terminal> {
        self.now = self.now.max(now);
        let entry = self.active.get(&id)?;
        let terminal = if entry.deadline.is_some_and(|d| self.now >= d) {
            Terminal::TimedOut
        } else {
            Terminal::Cancelled
        };
        self.settle(id, terminal).then_some(terminal)
    }
    /// Observe one timer without trusting its scheduler to fire exactly on time.
    pub fn timeout(&mut self, id: ExecutionId, now: u64) -> bool {
        self.now = self.now.max(now);
        if self
            .active
            .get(&id)
            .is_some_and(|e| e.deadline.is_some_and(|d| self.now >= d))
        {
            self.settle(id, Terminal::TimedOut)
        } else {
            false
        }
    }
    /// Acknowledge actual worker completion. Deadline arbitration happens here
    /// too: a delayed timer cannot turn late native completion into success.
    pub fn finish(&mut self, id: ExecutionId, now: u64) -> Option<Terminal> {
        self.now = self.now.max(now);
        let entry = self.active.remove(&id)?;
        if entry.terminal.is_some() {
            return None;
        }
        Some(if entry.deadline.is_some_and(|d| self.now >= d) {
            Terminal::TimedOut
        } else {
            Terminal::Completed
        })
    }
    /// Whether this reservation has not yet delivered a terminal event.
    pub fn is_active(&self, id: ExecutionId) -> bool {
        self.active.get(&id).is_some_and(|e| e.terminal.is_none())
    }
    /// Mark elapsed deadlines once; host callbacks and native cancellation happen outside this reducer.
    pub fn expire(&mut self, now: u64) -> Vec<ExecutionId> {
        self.now = self.now.max(now);
        let due: Vec<_> = self
            .active
            .iter()
            .filter_map(|(&id, e)| {
                (e.terminal.is_none() && e.deadline.is_some_and(|t| self.now >= t)).then_some(id)
            })
            .collect();
        for id in &due {
            self.settle(*id, Terminal::TimedOut);
        }
        due
    }
    /// Reject future reservations and claim cancellation for all unfinished deliveries.
    pub fn close(&mut self, now: u64) -> Vec<(ExecutionId, Terminal)> {
        self.closed = true;
        let ids: Vec<_> = self.active.keys().copied().collect();
        ids.into_iter()
            .filter_map(|id| self.cancel(id, now).map(|terminal| (id, terminal)))
            .collect()
    }
    /// Capacity held by actual workers, including those awaiting cancellation acknowledgement.
    pub fn active_count(&self) -> usize {
        self.active.len()
    }
}
