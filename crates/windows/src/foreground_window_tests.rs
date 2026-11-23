use super::*;
use std::cell::Cell;

fn methods() -> [Method; 4] {
    fn planned_method(json: &[u8]) -> Method {
        let action = ActionRequest::decode(json).unwrap();
        let mut plan = Plan::for_action(&action, Platform::Windows);
        assert_eq!(plan.steps.len(), 1);
        plan.steps.pop().unwrap().method
    }
    [
        Method::WindowClose {},
        Method::WindowMinimize {},
        planned_method(
            br#"{"kind":"action.window.placement","input":{"placement":{"kind":"fill"}}}"#,
        ),
        planned_method(br#"{"kind":"action.window.move","input":{"direction":"next"}}"#),
    ]
}

fn snapshot() -> windowing::WindowSnapshot {
    windowing::WindowSnapshot {
        identity: windowing::WindowIdentity {
            handle: 1,
            process: 2,
            thread: 3,
        },
        frame: Default::default(),
        title: String::new(),
        minimized: false,
        maximized: false,
    }
}

#[test]
fn cancellation_during_query_skips_all_four_foreground_window_effects() {
    for method in methods() {
        let cancelled = AtomicBool::new(false);
        let queries = Cell::new(0);
        let effects = Cell::new(0);
        let result = foreground_window_effect(
            &method,
            &cancelled,
            || {
                queries.set(queries.get() + 1);
                cancelled.store(true, Ordering::Release);
                Ok(snapshot())
            },
            |_, _| {
                effects.set(effects.get() + 1);
                ActionResult::success()
            },
        );
        assert_eq!(queries.get(), 1, "{method:?}");
        assert_eq!(effects.get(), 0, "{method:?}");
        assert_eq!(
            result,
            failure(ErrorCode::InternalError, "Execution cancelled", None),
            "{method:?}"
        );
    }
}

#[test]
fn uncancelled_query_applies_each_method_to_the_captured_window() {
    for method in methods() {
        let cancelled = AtomicBool::new(false);
        let effects = Cell::new(0);
        let result = foreground_window_effect(
            &method,
            &cancelled,
            || Ok(snapshot()),
            |selected, current| {
                assert_eq!(selected, &method);
                assert_eq!(current.identity, snapshot().identity);
                effects.set(effects.get() + 1);
                ActionResult::success()
            },
        );
        assert_eq!(result, ActionResult::success());
        assert_eq!(effects.get(), 1, "{method:?}");
    }
}

#[test]
fn cancellation_takes_precedence_over_a_query_error() {
    for error in [windowing::Error::Unavailable, windowing::Error::Native(5)] {
        let cancelled = AtomicBool::new(false);
        let result = foreground_window_effect(
            &Method::WindowMinimize {},
            &cancelled,
            || {
                cancelled.store(true, Ordering::Release);
                Err(error)
            },
            |_, _| panic!("A failed query must never apply a window effect"),
        );
        assert_eq!(
            result,
            failure(ErrorCode::InternalError, "Execution cancelled", None)
        );
    }
}

fn application() -> ApplicationSnapshot {
    use desktop_applications::{ApplicationIdentifier, IdentifierKind, ProcessIdentity};
    ApplicationSnapshot {
        identity: ProcessIdentity {
            process_id: snapshot().identity.process,
            start_time: 100,
        },
        identifier: Some(ApplicationIdentifier {
            kind: IdentifierKind::Executable,
            value: "C:\\fixture.exe".into(),
        }),
        display_name: None,
        terminated: false,
    }
}

#[test]
fn queued_target_rejects_replaced_handle_process_and_thread_before_an_effect() {
    let application = application();
    let window = snapshot().identity;
    for changed in [
        None,
        Some(windowing::WindowIdentity {
            handle: 4,
            ..window
        }),
        Some(windowing::WindowIdentity {
            process: 4,
            ..window
        }),
        Some(windowing::WindowIdentity {
            thread: 4,
            ..window
        }),
    ] {
        let result = check_target_with(
            &AtomicBool::new(false),
            Target {
                application: &application,
                window,
            },
            || changed,
            |_| Ok(application.clone()),
        );
        assert_eq!(result, Err(target_changed()));
    }
}

#[test]
fn process_lookup_cannot_silently_retarget_a_queued_effect() {
    let application = application();
    let window = snapshot().identity;
    let samples = Cell::new(0);
    let result = check_target_with(
        &AtomicBool::new(false),
        Target {
            application: &application,
            window,
        },
        || {
            samples.set(samples.get() + 1);
            Some(if samples.get() == 1 {
                window
            } else {
                windowing::WindowIdentity {
                    handle: 4,
                    ..window
                }
            })
        },
        |pid| {
            assert_eq!(pid, application.identity.process_id);
            Ok(application.clone())
        },
    );
    assert_eq!(result, Err(target_changed()));
    assert_eq!(samples.get(), 2);
}

#[test]
fn target_guard_preserves_cancellation_over_lookup_and_identity_failures() {
    let application = application();
    let cancelled = AtomicBool::new(false);
    let result = check_target_with(
        &cancelled,
        Target {
            application: &application,
            window: snapshot().identity,
        },
        || None,
        |_| {
            cancelled.store(true, Ordering::Release);
            Err(applications::Error::Native(5))
        },
    );
    assert_eq!(result, Err(cancelled_failure()));
}
