use desktop_actions::{
    ActionSequence, SequenceActionResult as Result, SequenceFailureBehavior as Failure,
    SequenceStatus as Status,
};

#[test]
fn requests_are_claimed_once_and_invalid_delivery_cannot_advance() {
    let mut sequence = ActionSequence::new(2, Failure::Continue);
    assert!(!sequence.record(1, Result::Success));
    assert_eq!(sequence.next_action(), Some(1));
    assert_eq!(sequence.next_action(), None);
    assert!(!sequence.record(2, Result::Success));
    assert!(sequence.record(1, Result::Success));
    assert!(!sequence.record(1, Result::Success));
    assert_eq!(sequence.next_action(), Some(2));
    assert!(sequence.record(2, Result::Success));
    assert_eq!(sequence.status(), Status::Completed);
    assert_eq!(sequence.recorded_count(), 2);
    assert!(sequence.all_actions_succeeded());
    sequence.cancel();
    assert_eq!(sequence.status(), Status::Completed);
    assert_eq!(sequence.next_action(), None);
}

#[test]
fn host_selects_continuation_after_completed_failure_or_skip() {
    for result in [Result::Failure, Result::Skipped] {
        for behavior in [Failure::Stop, Failure::Continue] {
            let mut sequence = ActionSequence::new(2, behavior);
            assert_eq!(sequence.next_action(), Some(1));
            assert!(sequence.record(1, result));
            assert!(!sequence.all_actions_succeeded());
            if behavior == Failure::Stop {
                assert_eq!(sequence.status(), Status::Stopped);
                assert_eq!(sequence.next_action(), None);
            } else {
                assert_eq!(sequence.next_action(), Some(2));
                assert!(sequence.record(2, Result::Success));
                assert_eq!(sequence.status(), Status::Completed);
                assert!(!sequence.all_actions_succeeded());
            }
        }
    }
}

#[test]
fn unacknowledged_workers_and_capacity_rejection_stop_both_policies() {
    for (result, status) in [
        (Result::Cancelled, Status::Cancelled),
        (Result::TimedOut, Status::TimedOut),
        (Result::Busy, Status::Busy),
    ] {
        for behavior in [Failure::Stop, Failure::Continue] {
            let mut sequence = ActionSequence::new(2, behavior);
            assert_eq!(sequence.next_action(), Some(1));
            assert!(sequence.record(1, result));
            assert_eq!(sequence.status(), status);
            assert_eq!(sequence.next_action(), None);
            assert!(!sequence.all_actions_succeeded());
        }
    }
}

#[test]
fn cancellation_retains_recorded_progress_and_refuses_late_results() {
    let mut sequence = ActionSequence::new(3, Failure::Continue);
    assert_eq!(sequence.next_action(), Some(1));
    assert!(sequence.record(1, Result::Success));
    assert_eq!(sequence.next_action(), Some(2));
    sequence.cancel();
    assert!(!sequence.record(2, Result::Success));
    assert_eq!(sequence.recorded_count(), 1);
    assert_eq!(sequence.status(), Status::Cancelled);
    assert_eq!(sequence.next_action(), None);
}

#[test]
fn a_cancelled_second_delivery_preserves_progress_and_never_claims_the_third_request() {
    for behavior in [Failure::Stop, Failure::Continue] {
        let mut sequence = ActionSequence::new(3, behavior);
        assert_eq!(sequence.next_action(), Some(1));
        assert!(sequence.record(1, Result::Success));
        assert_eq!(sequence.next_action(), Some(2));
        assert!(sequence.record(2, Result::Cancelled));
        assert_eq!(sequence.status(), Status::Cancelled);
        assert_eq!(sequence.recorded_count(), 2);
        assert!(!sequence.all_actions_succeeded());
        assert!(!sequence.record(2, Result::Failure));
        assert_eq!(sequence.next_action(), None);
    }
}

#[test]
fn empty_sequences_are_successful_without_a_callback_or_allocation() {
    let mut sequence = ActionSequence::new(0, Failure::Stop);
    assert_eq!(sequence.status(), Status::Completed);
    assert!(sequence.all_actions_succeeded());
    assert_eq!(sequence.next_action(), None);
    sequence.cancel();
    assert!(sequence.all_actions_succeeded());
}
