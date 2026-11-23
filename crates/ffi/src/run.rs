use crate::DesktopActionsJson;
use desktop_actions::{ActionExecution, ActionRequest, ActionResult, Method, Plan, Step};
use serde::Serialize;
use std::sync::Mutex;

pub struct DesktopActionsActionRun(Mutex<ActionExecution>);
/// # Safety
/// Input is readable for length bytes. Kind 0 is a raw action, 1 is an array of
/// plan steps. Invalid actions become an invalid-input instruction, with no effects.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn desktop_actions_run_create(
    data: *const u8,
    length: usize,
    target: u32,
    kind: u32,
) -> *mut DesktopActionsActionRun {
    let Some(platform) = crate::platform(target) else {
        return std::ptr::null_mut();
    };
    if data.is_null() || length == 0 || length > isize::MAX as usize {
        return std::ptr::null_mut();
    }
    let bytes = unsafe { std::slice::from_raw_parts(data, length) };
    let plan = match kind {
        0 => match ActionRequest::decode(bytes) {
            Ok(action) => Plan::for_action(&action, platform),
            Err(error) => {
                let steps = vec![Step {
                    method: Method::InvalidInput {
                        message: error.message,
                    },
                    is_fallback: false,
                }];
                Plan::from_steps(steps, platform)
            }
        },
        1 => match serde_json::from_slice::<Vec<Step>>(bytes) {
            Ok(steps) => Plan::from_steps(steps, platform),
            Err(_) => return std::ptr::null_mut(),
        },
        _ => return std::ptr::null_mut(),
    };
    Box::into_raw(Box::new(DesktopActionsActionRun(Mutex::new(
        ActionExecution::new(plan),
    ))))
}
/// # Safety
/// Run must be live. The returned owned JSON is null at completion or contains
/// id and step; claiming another step before recording the current one fails.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn desktop_actions_run_next(
    run: *const DesktopActionsActionRun,
) -> *mut DesktopActionsJson {
    let Some(run) = (unsafe { run.as_ref() }) else {
        return DesktopActionsJson::invalid();
    };
    #[derive(Serialize)]
    struct Next {
        id: u64,
        step: Step,
    }
    let next = run.0.lock().unwrap_or_else(|e| e.into_inner()).next_step();
    match next {
        Ok(step) => DesktopActionsJson::result(Ok(serde_json::to_vec(
            &step.map(|(id, step)| Next { id, step }),
        )
        .expect("native step"))),
        Err(_) => DesktopActionsJson::invalid(),
    }
}
/// # Safety
/// Run and result bytes must be live. Zero means accepted; one means invalid input
/// or sequence. Failed records leave the outstanding step unchanged.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn desktop_actions_run_record(
    run: *const DesktopActionsActionRun,
    id: u64,
    data: *const u8,
    length: usize,
    duration_seconds: f64,
    has_duration: u32,
) -> u32 {
    let Some(run) = (unsafe { run.as_ref() }) else {
        return 1;
    };
    if data.is_null() || length == 0 || length > isize::MAX as usize || has_duration > 1 {
        return 1;
    }
    let bytes = unsafe { std::slice::from_raw_parts(data, length) };
    let Ok(result) = serde_json::from_slice::<ActionResult>(bytes) else {
        return 1;
    };
    let duration = (has_duration == 1).then_some(duration_seconds);
    u32::from(
        run.0
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .record(id, result, duration)
            .is_err(),
    )
}
/// # Safety
/// Run must be live. A completed report owns its outcome and callback metadata;
/// reporting before completion fails. No callback is invoked by this function.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn desktop_actions_run_report(
    run: *const DesktopActionsActionRun,
) -> *mut DesktopActionsJson {
    let Some(run) = (unsafe { run.as_ref() }) else {
        return DesktopActionsJson::invalid();
    };
    #[derive(Serialize)]
    #[serde(rename_all = "camelCase")]
    struct Report {
        outcome: desktop_actions::ActionExecutionReport,
        notify_automation_denied: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        automation_error_number: Option<i64>,
    }
    let state = run.0.lock().unwrap_or_else(|e| e.into_inner());
    let (Ok(outcome), Ok(denial)) = (state.report(), state.automation_denial()) else {
        return DesktopActionsJson::invalid();
    };
    DesktopActionsJson::result(Ok(serde_json::to_vec(&Report {
        outcome,
        notify_automation_denied: denial.is_some(),
        automation_error_number: denial.flatten(),
    })
    .expect("native report")))
}
/// # Safety
/// Run must be null or exclusively owned, with no concurrent calls remaining.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn desktop_actions_run_destroy(run: *mut DesktopActionsActionRun) {
    if !run.is_null() {
        drop(unsafe { Box::from_raw(run) });
    }
}
