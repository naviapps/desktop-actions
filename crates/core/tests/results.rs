use desktop_actions::{
    ActionError, ActionExecution, ActionExecutionReport, ActionKind, ActionRequest, ActionResult,
    Attempt, ErrorCode, ErrorSpec, ExecutionError, Permission, Plan, Platform,
};

fn error(code: ErrorCode, permission: Option<Permission>, number: Option<i64>) -> ActionError {
    ActionError::new(ErrorSpec {
        code,
        diagnostic_message: "test failure".into(),
        permission,
        apple_script_error_number: number,
        native_code: None,
    })
    .unwrap()
}
#[test]
fn error_wire_rejects_invalid_diagnostics_and_incompatible_metadata() {
    for raw in [
        r#"{"code":"open-failed","diagnosticMessage":" "}"#,
        r#"{"code":"permission-denied","diagnosticMessage":"denied"}"#,
        r#"{"code":"not-found","diagnosticMessage":"missing","permission":"automation"}"#,
        r#"{"code":"apple-script-failed","diagnosticMessage":"failed","permission":"automation"}"#,
        r#"{"code":"permission-denied","diagnosticMessage":"denied","permission":"accessibility","appleScriptErrorNumber":-1743}"#,
        r#"{"code":"apple-script-failed","diagnosticMessage":"failed","appleScriptErrorNumber":null}"#,
        r#"{"code":"open-failed","diagnosticMessage":"failed","nativeCode":5}"#,
        r#"{"code":"native-failed","diagnosticMessage":"failed","nativeCode":null}"#,
        r#"{"code":"native-failed","diagnosticMessage":"failed","nativeCode":9223372036854775808}"#,
        r#"{"code":"open-failed","diagnosticMessage":"failed","unknown":true}"#,
        r#"{"code":"open-failed","code":"native-failed","diagnosticMessage":"failed"}"#,
    ] {
        assert!(
            serde_json::from_slice::<ActionError>(raw.as_bytes()).is_err(),
            "{raw}"
        );
    }
}

#[test]
fn result_wire_requires_the_fields_for_its_status() {
    for raw in [
        r#"{"skipReason":"no-focused-window"}"#,
        r#"{"status":"skipped"}"#,
        r#"{"status":"failure"}"#,
        r#"{"status":"success","error":{}}"#,
        r#"{"status":"success","skipReason":"no-focused-window"}"#,
        r#"{"status":"skipped","skipReason":"no-focused-window","error":{}}"#,
        r#"{"status":"failure","error":{"code":"not-found","diagnosticMessage":"missing"},"skipReason":"no-focused-window"}"#,
        r#"{"status":"success","extra":null}"#,
        r#"{"status":"success","status":"success"}"#,
        r#"{"status":"success","status":"failure"}"#,
        r#"{"status":"failure","error":{"code":"not-found","diagnosticMessage":"missing","permission":"automation"}}"#,
        r#"{"status":"failure","error":{"code":"permission-denied","diagnosticMessage":"denied","permission":null}}"#,
        r#"{"status":"failure","error":{"code":"permission-denied","diagnosticMessage":"denied","permission":"accessibility","appleScriptErrorNumber":-1743}}"#,
        r#"{"status":"failure","error":{"code":"native-failed","diagnosticMessage":"failed","nativeCode":5,"nativeCode":87}}"#,
    ] {
        assert!(
            serde_json::from_slice::<ActionResult>(raw.as_bytes()).is_err(),
            "{raw}"
        );
    }
}

#[test]
fn attempt_wire_requires_complete_fields_and_valid_durations() {
    for raw in [
        r#"{"requiredPermissions":["automation","automation"],"isFallback":false,"result":{"status":"success"}}"#,
        r#"{"requiredPermissions":[],"result":{"status":"success"}}"#,
        r#"{"isFallback":false,"result":{"status":"success"}}"#,
        r#"{"requiredPermissions":[],"isFallback":false}"#,
    ] {
        assert!(
            serde_json::from_slice::<Attempt>(raw.as_bytes()).is_err(),
            "{raw}"
        );
    }
    for value in [
        "-1",
        "null",
        "9223372036854775808",
        "1e100",
        "true",
        "\"0.25\"",
    ] {
        let raw = format!(
            r#"{{"requiredPermissions":[],"isFallback":false,"result":{{"status":"success"}},"durationSeconds":{value}}}"#
        );
        assert!(
            serde_json::from_slice::<Attempt>(raw.as_bytes()).is_err(),
            "{raw}"
        );
    }
}

#[test]
fn report_wire_requires_valid_history_matching_its_final_result() {
    for raw in [
        r#"{"finalResult":{"status":"success"},"attempts":[]}"#,
        r#"{"finalResult":{"status":"skipped","skipReason":"no-focused-window"},"attempts":[{"requiredPermissions":[],"isFallback":false,"result":{"status":"success"}}]}"#,
        r#"{"finalResult":{"status":"success"},"attempts":[{"requiredPermissions":[],"isFallback":false,"result":{"status":"skipped","skipReason":"no-focused-window"}}]}"#,
        r#"{"finalResult":{"status":"success"},"attempts":[{"requiredPermissions":[],"isFallback":false,"result":{"status":"success","extra":1}}]}"#,
        r#"{"finalResult":{"status":"failure","error":{"code":"native-failed","diagnosticMessage":"failed"}},"attempts":[{"requiredPermissions":[],"isFallback":false,"result":{"status":"success"}}]}"#,
    ] {
        assert!(
            serde_json::from_slice::<ActionExecutionReport>(raw.as_bytes()).is_err(),
            "{raw}"
        );
    }
}

#[test]
fn result_values_use_exact_diagnostics_and_numeric_durations() {
    let make_error = |message: &str| {
        ActionError::new(ErrorSpec {
            code: ErrorCode::InvalidInput,
            diagnostic_message: message.into(),
            permission: None,
            apple_script_error_number: None,
            native_code: None,
        })
        .unwrap()
    };
    let composed = make_error("caf\u{e9}");
    let decomposed = make_error("cafe\u{301}");
    assert_ne!(composed, decomposed);

    let attempt = Attempt::new([].into(), false, ActionResult::failure(composed), None).unwrap();
    let report = ActionExecutionReport::new(vec![attempt]);
    let mut wire = serde_json::to_value(report).unwrap();
    wire["finalResult"] = serde_json::to_value(ActionResult::failure(decomposed)).unwrap();
    assert!(serde_json::from_value::<ActionExecutionReport>(wire).is_err());

    let measured =
        |duration| Attempt::new([].into(), false, ActionResult::success(), duration).unwrap();
    let zero = measured(Some(0.0));
    let tiny = measured(Some(1e-19));
    assert_eq!(zero, measured(Some(-0.0)));
    assert_ne!(zero, tiny);
    assert_ne!(zero, measured(None));
    assert_ne!(
        ActionExecutionReport::new(vec![zero.clone(), tiny.clone(), measured(None)]),
        ActionExecutionReport::new(vec![tiny, zero, measured(None)])
    );
}

#[test]
fn results_round_trip_and_empty_internal_outcomes_remain_explicit_failures() {
    let attempt = Attempt::new(
        [Permission::Automation, Permission::Accessibility].into(),
        true,
        ActionResult::failure(error(
            ErrorCode::PermissionDenied,
            Some(Permission::Automation),
            Some(-1743),
        )),
        Some(0.25),
    )
    .unwrap();
    let outcome = ActionExecutionReport::new(vec![attempt]);
    let data = serde_json::to_vec(&outcome).unwrap();
    assert_eq!(
        serde_json::from_slice::<ActionExecutionReport>(&data).unwrap(),
        outcome
    );
    assert!(outcome.did_attempt_fallback());
    assert!(matches!(
        ActionExecutionReport::new(vec![]).final_result(),
        ActionResult::Failure { .. }
    ));
}
#[test]
fn finite_duration_round_trip_preserves_values_next_to_the_upper_bound() {
    let value = f64::from_bits(9_223_372_036_854_775_808.0_f64.to_bits() - 1);
    let attempt = Attempt::new(
        Default::default(),
        false,
        ActionResult::success(),
        Some(value),
    )
    .unwrap();
    let bytes = serde_json::to_vec(&attempt).unwrap();
    assert_eq!(
        serde_json::from_slice::<Attempt>(&bytes).unwrap(),
        attempt,
        "{}",
        String::from_utf8_lossy(&bytes)
    );
}
#[test]
fn reducer_rejects_out_of_order_records_and_recovers_without_losing_the_step() {
    let plan = Plan::for_action(
        &ActionRequest::new(ActionKind::ShowDesktop, None).unwrap(),
        Platform::Macos,
    );
    let mut run = ActionExecution::new(plan);
    assert_eq!(run.report(), Err(ExecutionError::NotFinished));
    let (id, _) = run.next_step().unwrap().unwrap();
    assert_eq!(run.next_step(), Err(ExecutionError::StepOutstanding));
    assert_eq!(
        run.record(id + 1, ActionResult::success(), None),
        Err(ExecutionError::InvalidStep)
    );
    assert_eq!(
        run.record(id, ActionResult::success(), Some(f64::NAN)),
        Err(ExecutionError::InvalidDuration)
    );
    run.record(id, ActionResult::success(), Some(0.1)).unwrap();
    assert!(run.next_step().unwrap().is_none());
    assert_eq!(run.report().unwrap().attempts().len(), 1);
    assert_eq!(
        run.record(id, ActionResult::success(), None),
        Err(ExecutionError::InvalidStep)
    );
}

#[test]
fn copy_runs_retain_the_same_report_after_rejected_and_replayed_records() {
    use serde_json::json;

    let request = ActionRequest::decode(br#"{"kind":"action.editing.copy"}"#).unwrap();
    for (platform, key_code, modifiers, permissions) in [
        (Platform::Macos, 8, 1, json!(["accessibility"])),
        (Platform::Windows, 67, 8, json!([])),
    ] {
        let mut run = ActionExecution::new(Plan::for_action(&request, platform));
        assert_eq!(run.report(), Err(ExecutionError::NotFinished));
        let (id, step) = run.next_step().unwrap().unwrap();
        assert_eq!(id, 1);
        assert_eq!(
            serde_json::to_value(step).unwrap(),
            json!({"method":{"kind":"key-event","keyCode":key_code,"modifiers":modifiers},"isFallback":false})
        );
        assert_eq!(run.next_step(), Err(ExecutionError::StepOutstanding));
        for (record_id, duration, error) in [
            (99, 0.25, ExecutionError::InvalidStep),
            (id, f64::NAN, ExecutionError::InvalidDuration),
        ] {
            assert_eq!(
                run.record(record_id, ActionResult::success(), Some(duration)),
                Err(error)
            );
            assert_eq!(run.next_step(), Err(ExecutionError::StepOutstanding));
        }
        run.record(id, ActionResult::success(), Some(0.25)).unwrap();
        let expected = json!({
            "finalResult":{"status":"success"},
            "attempts":[{
                "requiredPermissions":permissions,"isFallback":false,
                "result":{"status":"success"},"durationSeconds":0.25
            }]
        });
        assert_eq!(
            serde_json::to_value(run.report().unwrap()).unwrap(),
            expected
        );
        assert_eq!(run.next_step().unwrap(), None);
        assert_eq!(
            run.record(id, ActionResult::success(), Some(0.25)),
            Err(ExecutionError::InvalidStep)
        );
        assert_eq!(
            serde_json::to_value(run.report().unwrap()).unwrap(),
            expected
        );
        assert_eq!(run.automation_denial().unwrap(), None);
    }
}

#[test]
fn automation_denial_notification_is_selected_after_the_actual_fallback_result() {
    for (last, expected) in [
        (ActionResult::success(), None),
        (
            ActionResult::failure(error(
                ErrorCode::PermissionDenied,
                Some(Permission::Accessibility),
                None,
            )),
            None,
        ),
        (
            ActionResult::failure(error(ErrorCode::NativeFailed, None, None)),
            Some(Some(-1743)),
        ),
    ] {
        let plan = Plan::for_action(
            &ActionRequest::new(ActionKind::ShowDesktop, None).unwrap(),
            Platform::Macos,
        );
        let mut run = ActionExecution::new(plan);
        let (id, _) = run.next_step().unwrap().unwrap();
        run.record(
            id,
            ActionResult::failure(error(
                ErrorCode::PermissionDenied,
                Some(Permission::Automation),
                Some(-1743),
            )),
            None,
        )
        .unwrap();
        let (id, _) = run.next_step().unwrap().unwrap();
        run.record(id, last, None).unwrap();
        assert_eq!(run.automation_denial().unwrap(), expected);
    }
}
