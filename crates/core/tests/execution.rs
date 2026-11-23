use desktop_actions::*;
#[test]
fn delayed_timeout_observer_does_not_turn_late_completion_into_success() {
    let mut pool = ExecutionPool::new(1, 10).unwrap();
    let id = pool.reserve(0, false).unwrap();
    assert_eq!(pool.reserve(20, false), None);
    assert_eq!(pool.finish(id, 20), Some(Terminal::TimedOut));
}
#[test]
fn terminal_delivery_and_capacity_wait_for_actual_completion() {
    let mut pool = ExecutionPool::new(1, 10).unwrap();
    let id = pool.reserve(5, false).unwrap();
    assert_eq!(pool.deadline(id), Some(15));
    assert_eq!(pool.expire(15), [id]);
    assert!(pool.expire(20).is_empty());
    assert_eq!(pool.active_count(), 1);
    assert_eq!(pool.reserve(20, false), None);
    assert_eq!(pool.finish(id, 20), None);
    assert_eq!(pool.active_count(), 0);
    assert!(pool.reserve(20, false).is_some());
}
#[test]
fn completion_cancellation_and_close_are_exactly_once() {
    let mut pool = ExecutionPool::new(3, 10).unwrap();
    let a = pool.reserve(0, false).unwrap();
    let b = pool.reserve(0, true).unwrap();
    assert_eq!(pool.deadline(b), None);
    assert_eq!(pool.finish(a, 1), Some(Terminal::Completed));
    assert_eq!(pool.finish(a, 1), None);
    assert_eq!(pool.close(2), [(b, Terminal::Cancelled)]);
    assert_eq!(pool.cancel(b, 2), None);
    assert_eq!(pool.reserve(30, false), None);
    assert_eq!(pool.finish(b, 30), None);
}
#[test]
fn invalid_policy_is_rejected_without_substitution() {
    assert!(ExecutionPool::new(0, 10).is_none());
    assert!(ExecutionPool::new(1, 0).is_none());
}
