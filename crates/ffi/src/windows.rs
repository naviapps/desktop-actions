use crate::DesktopActionsJson;
#[cfg(not(windows))]
use desktop_actions::{ActionError, ActionResult, Attempt, ErrorCode, ErrorSpec};
use desktop_actions::{ActionExecutionReport, ActionRequest};
use serde::Serialize;
use std::sync::atomic::{AtomicBool, Ordering};

pub struct DesktopActionsWindowsRun {
    action: ActionRequest,
    target: Option<DesktopActionsWindowsTarget>,
    cancelled: AtomicBool,
    started: AtomicBool,
}

#[derive(Clone)]
pub struct DesktopActionsWindowsTarget {
    #[cfg(windows)]
    snapshot: desktop_actions_windows::ForegroundTarget,
    #[cfg(not(windows))]
    _unsupported: std::convert::Infallible,
}

/// Owns a best-effort capture of the current Windows foreground target. Null
/// indicates no complete stable target or an unavailable Windows adapter.
#[unsafe(no_mangle)]
pub extern "C" fn desktop_actions_windows_target_capture() -> *mut DesktopActionsWindowsTarget {
    #[cfg(windows)]
    {
        desktop_actions_windows::ForegroundTarget::capture()
            .map_or(std::ptr::null_mut(), |snapshot| {
                Box::into_raw(Box::new(DesktopActionsWindowsTarget { snapshot }))
            })
    }
    #[cfg(not(windows))]
    std::ptr::null_mut()
}

/// # Safety
/// Target must be null or exclusively owned. Run creation using it must have returned.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn desktop_actions_windows_target_destroy(
    target: *mut DesktopActionsWindowsTarget,
) {
    if !target.is_null() {
        drop(unsafe { Box::from_raw(target) });
    }
}

/// # Safety
/// Input must be readable for length bytes and contain a bare action. Target
/// must be live during creation. The run owns its own snapshot. Null target or
/// invalid action returns null and never creates an unguarded run.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn desktop_actions_windows_create_for_target(
    data: *const u8,
    length: usize,
    target: *const DesktopActionsWindowsTarget,
) -> *mut DesktopActionsWindowsRun {
    #[cfg(windows)]
    {
        let Some(target) = (unsafe { target.as_ref() }) else {
            return std::ptr::null_mut();
        };
        unsafe { create_run(data, length, Some(target.clone())) }
    }
    #[cfg(not(windows))]
    {
        let _ = (data, length, target);
        std::ptr::null_mut()
    }
}

/// # Safety
/// Input must be readable for length bytes and contain a bare action. The run owns
/// a copy and does not perform effects during creation. Invalid input returns null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn desktop_actions_windows_create(
    data: *const u8,
    length: usize,
) -> *mut DesktopActionsWindowsRun {
    unsafe { create_run(data, length, None) }
}

unsafe fn create_run(
    data: *const u8,
    length: usize,
    target: Option<DesktopActionsWindowsTarget>,
) -> *mut DesktopActionsWindowsRun {
    if data.is_null() || length == 0 || length > isize::MAX as usize {
        return std::ptr::null_mut();
    }
    let Ok(action) = ActionRequest::decode(unsafe { std::slice::from_raw_parts(data, length) })
    else {
        return std::ptr::null_mut();
    };
    Box::into_raw(Box::new(DesktopActionsWindowsRun {
        action,
        target,
        cancelled: AtomicBool::new(false),
        started: AtomicBool::new(false),
    }))
}
/// # Safety
/// Run must remain live. May be called concurrently with execute. This never
/// closes applications or pretends an already accepted native effect was undone.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn desktop_actions_windows_cancel(run: *const DesktopActionsWindowsRun) {
    if let Some(run) = unsafe { run.as_ref() } {
        run.cancelled.store(true, Ordering::Release);
    }
}
#[derive(Serialize)]
#[serde(tag = "status", rename_all = "kebab-case")]
enum Report {
    Completed { outcome: ActionExecutionReport },
    Cancelled {},
}
/// # Safety
/// Run must be live until this blocking call returns. It may execute once only.
/// Owned JSON reports completed{outcome} or cancelled. No host callback is invoked.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn desktop_actions_windows_execute(
    run: *const DesktopActionsWindowsRun,
) -> *mut DesktopActionsJson {
    let Some(run) = (unsafe { run.as_ref() }) else {
        return DesktopActionsJson::invalid();
    };
    if run.started.swap(true, Ordering::AcqRel) {
        return DesktopActionsJson::invalid();
    }
    let report = if run.cancelled.load(Ordering::Acquire) {
        Report::Cancelled {}
    } else {
        #[cfg(windows)]
        let outcome = match &run.target {
            Some(target) => target.snapshot.execute(&run.action, &run.cancelled),
            None => desktop_actions_windows::execute(&run.action, &run.cancelled),
        };
        #[cfg(not(windows))]
        let outcome = {
            let _request = (&run.action, &run.target);
            let error = ActionError::new(ErrorSpec {
                code: ErrorCode::UnsupportedAction,
                diagnostic_message: "The Windows adapter is unavailable on this OS".into(),
                permission: None,
                apple_script_error_number: None,
                native_code: None,
            })
            .unwrap();
            Some(ActionExecutionReport::new(vec![
                Attempt::new(
                    Default::default(),
                    false,
                    ActionResult::failure(error),
                    None,
                )
                .unwrap(),
            ]))
        };
        outcome.map_or(Report::Cancelled {}, |outcome| Report::Completed {
            outcome,
        })
    };
    DesktopActionsJson::result(Ok(
        serde_json::to_vec(&report).expect("native execution report")
    ))
}
/// # Safety
/// Run must be null or exclusively owned; execute and cancel must have returned.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn desktop_actions_windows_destroy(run: *mut DesktopActionsWindowsRun) {
    if !run.is_null() {
        drop(unsafe { Box::from_raw(run) });
    }
}
