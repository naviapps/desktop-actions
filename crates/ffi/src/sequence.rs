use desktop_actions::{ActionSequence, SequenceActionResult, SequenceFailureBehavior};
use std::sync::Mutex;

pub struct DesktopActionsActionSequence(Mutex<ActionSequence>);

/// Status is 0 running, 1 completed, 2 stopped on failure, 3 cancelled, 4 timed
/// out or 5 busy. Completed means every delivery was recorded. Check
/// all_actions_succeeded for aggregate success.
#[repr(C)]
pub struct DesktopActionsSequenceSummary {
    pub status: u32,
    pub all_actions_succeeded: u32,
    pub recorded_count: usize,
}

/// Creates an ordered sequence. Failure behavior 0 stops on completed failure
/// or skip, and 1 continues. Cancellation, timeout and capacity rejection always
/// stop issuance. The caller owns effects, values and reports. Invalid policy returns null.
#[unsafe(no_mangle)]
pub extern "C" fn desktop_actions_sequence_create(
    count: usize,
    failure_behavior: u32,
) -> *mut DesktopActionsActionSequence {
    let behavior = match failure_behavior {
        0 => SequenceFailureBehavior::Stop,
        1 => SequenceFailureBehavior::Continue,
        _ => return std::ptr::null_mut(),
    };
    Box::into_raw(Box::new(DesktopActionsActionSequence(Mutex::new(
        ActionSequence::new(count, behavior),
    ))))
}

/// # Safety
/// The owner must remain live. IDs start at one. Zero means no claim, including
/// an outstanding request or a terminal sequence.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn desktop_actions_sequence_next(
    owner: *const DesktopActionsActionSequence,
) -> usize {
    unsafe { owner.as_ref() }
        .and_then(|owner| {
            owner
                .0
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .next_action()
        })
        .unwrap_or(0)
}

/// Result is 1 success, 2 failure, 3 skipped, 4 cancelled, 5 timed out or 6 busy.
///
/// # Safety
/// The owner must remain live. Zero means accepted. Invalid ids/results never advance state.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn desktop_actions_sequence_record(
    owner: *const DesktopActionsActionSequence,
    id: usize,
    result: u32,
) -> u32 {
    let result = match result {
        1 => SequenceActionResult::Success,
        2 => SequenceActionResult::Failure,
        3 => SequenceActionResult::Skipped,
        4 => SequenceActionResult::Cancelled,
        5 => SequenceActionResult::TimedOut,
        6 => SequenceActionResult::Busy,
        _ => return 1,
    };
    u32::from(!unsafe { owner.as_ref() }.is_some_and(|owner| {
        owner
            .0
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .record(id, result)
    }))
}

/// # Safety
/// The owner must remain live. No callback or effect occurs under its lock.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn desktop_actions_sequence_cancel(
    owner: *const DesktopActionsActionSequence,
) {
    if let Some(owner) = unsafe { owner.as_ref() } {
        owner.0.lock().unwrap_or_else(|e| e.into_inner()).cancel();
    }
}

/// # Safety
/// The owner must remain live. Null returns UINT32_MAX status and zero aggregate success.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn desktop_actions_sequence_summary(
    owner: *const DesktopActionsActionSequence,
) -> DesktopActionsSequenceSummary {
    let Some(owner) = (unsafe { owner.as_ref() }) else {
        return DesktopActionsSequenceSummary {
            status: u32::MAX,
            all_actions_succeeded: 0,
            recorded_count: 0,
        };
    };
    let state = owner.0.lock().unwrap_or_else(|e| e.into_inner());
    DesktopActionsSequenceSummary {
        status: state.status() as u32,
        all_actions_succeeded: u32::from(state.all_actions_succeeded()),
        recorded_count: state.recorded_count(),
    }
}

/// # Safety
/// Null or an exclusively owned handle with no concurrent calls or live references.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn desktop_actions_sequence_destroy(
    owner: *mut DesktopActionsActionSequence,
) {
    if !owner.is_null() {
        drop(unsafe { Box::from_raw(owner) });
    }
}
