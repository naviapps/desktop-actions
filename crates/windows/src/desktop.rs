use crate::input::{self, Edge, InputError, Key};
use desktop_actions::{
    ActionError, ActionExecution, ActionExecutionReport, ActionRequest, ActionResult, ErrorCode,
    ErrorSpec, Method, Plan, Platform, SkipReason, parse_shortcut,
};
use desktop_applications::ApplicationSnapshot;
use desktop_applications_windows as applications;
use std::{
    ptr::null,
    sync::{
        Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::Instant,
};
use window_management_windows as windowing;
use windows_sys::Win32::{
    Foundation::*,
    System::{Com::*, Shutdown::LockWorkStation, Threading::GetCurrentProcessId},
    UI::{Input::KeyboardAndMouse::*, Shell::*, WindowsAndMessaging::*},
};

fn failure(code: ErrorCode, message: &str, native_code: Option<i64>) -> ActionResult {
    ActionResult::failure(
        ActionError::new(ErrorSpec {
            code,
            diagnostic_message: message.into(),
            permission: None,
            apple_script_error_number: None,
            native_code,
        })
        .expect("native failure specification"),
    )
}
fn native_failure(message: &str, code: u32) -> ActionResult {
    failure(
        if code == ERROR_ACCESS_DENIED {
            ErrorCode::AccessDenied
        } else {
            ErrorCode::NativeFailed
        },
        message,
        Some(code.into()),
    )
}
fn unsupported() -> ActionResult {
    failure(
        ErrorCode::UnsupportedAction,
        "This operation is unavailable on Windows",
        None,
    )
}
fn window_failure(error: windowing::Error) -> ActionResult {
    match error {
        windowing::Error::Unavailable => failure(
            ErrorCode::NotFound,
            "Requested window or screen is unavailable",
            None,
        ),
        windowing::Error::InvalidInput => failure(
            ErrorCode::InvalidInput,
            "Invalid window operation input",
            None,
        ),
        windowing::Error::TargetChanged => failure(
            ErrorCode::NativeFailed,
            "Window identity changed before the operation",
            None,
        ),
        windowing::Error::Native(code) => native_failure("Native window operation failed", code),
    }
}
fn application_failure(error: applications::Error) -> ActionResult {
    match error {
        applications::Error::InvalidInput => {
            failure(ErrorCode::InvalidInput, "Invalid application request", None)
        }
        applications::Error::Unavailable => {
            failure(ErrorCode::NotFound, "Application is unavailable", None)
        }
        applications::Error::TargetChanged => failure(
            ErrorCode::NativeFailed,
            "Application process identity changed",
            None,
        ),
        applications::Error::RequestRejected => failure(
            ErrorCode::NativeFailed,
            "Application request rejected",
            None,
        ),
        applications::Error::Native(code) => {
            native_failure("Native application operation failed", code)
        }
    }
}
/// No input, windows or processes are touched if cancellation is already set.
/// Cancellation cannot undo an OS request that has already been accepted.
pub fn execute(action: &ActionRequest, cancelled: &AtomicBool) -> Option<ActionExecutionReport> {
    execute_with_target(action, cancelled, None)
}

/// Execute only while the captured application and foreground window still match.
/// Hosts capture both before queuing work and retain ownership of target transitions
/// between actions. This does not make SendInput atomic with foreground changes.
/// Cancellation returns None; a changed or incomplete target produces a failed report.
pub fn execute_for_target(
    action: &ActionRequest,
    cancelled: &AtomicBool,
    application: &ApplicationSnapshot,
    window: windowing::WindowIdentity,
) -> Option<ActionExecutionReport> {
    execute_with_target(
        action,
        cancelled,
        Some(Target {
            application,
            window,
        }),
    )
}

/// An owned foreground window and process identity captured before queuing effects.
#[derive(Clone)]
pub struct ForegroundTarget {
    application: ApplicationSnapshot,
    window: windowing::WindowIdentity,
}

impl ForegroundTarget {
    /// Capture a stable foreground observation without requesting an effect.
    pub fn capture() -> Option<Self> {
        let window = foreground_identity()?;
        let application = crate::target::capture_application(
            window.process,
            |process| applications::application(process).ok(),
            || foreground_identity() == Some(window),
        )?;
        Some(Self {
            application,
            window,
        })
    }

    /// Execute using the existing captured-target check at each native effect.
    pub fn execute(
        &self,
        action: &ActionRequest,
        cancelled: &AtomicBool,
    ) -> Option<ActionExecutionReport> {
        execute_for_target(action, cancelled, &self.application, self.window)
    }
}

#[derive(Clone, Copy)]
struct Target<'a> {
    application: &'a ApplicationSnapshot,
    window: windowing::WindowIdentity,
}

fn target_changed() -> ActionResult {
    failure(
        ErrorCode::NativeFailed,
        "Foreground target changed before the operation",
        None,
    )
}

fn cancelled_failure() -> ActionResult {
    failure(ErrorCode::InternalError, "Execution cancelled", None)
}

fn foreground_identity() -> Option<windowing::WindowIdentity> {
    let handle = unsafe { GetForegroundWindow() };
    if handle.is_null() {
        return None;
    }
    let mut process = 0;
    let thread = unsafe { GetWindowThreadProcessId(handle, &mut process) };
    if process == 0 || thread == 0 {
        return None;
    }
    Some(windowing::WindowIdentity {
        handle: handle as usize as u64,
        process,
        thread,
    })
}

fn check_target(cancelled: &AtomicBool, target: Option<Target<'_>>) -> Result<(), ActionResult> {
    if cancelled.load(Ordering::Acquire) {
        return Err(cancelled_failure());
    }
    let Some(target) = target else {
        return Ok(());
    };
    check_target_with(
        cancelled,
        target,
        foreground_identity,
        applications::application,
    )
}

fn check_target_with(
    cancelled: &AtomicBool,
    target: Target<'_>,
    mut query_window: impl FnMut() -> Option<windowing::WindowIdentity>,
    query_application: impl FnOnce(u32) -> Result<ApplicationSnapshot, applications::Error>,
) -> Result<(), ActionResult> {
    if cancelled.load(Ordering::Acquire) {
        return Err(cancelled_failure());
    }
    // Query the recorded process, never select a replacement foreground application.
    // Check the foreground identity on both sides of the process query, which can wait.
    let before = query_window();
    let application = query_application(target.application.identity.process_id);
    let after = query_window();
    if cancelled.load(Ordering::Acquire) {
        return Err(cancelled_failure());
    }
    if before != Some(target.window) || after != Some(target.window) {
        return Err(target_changed());
    }
    let current = application.map_err(|error| match error {
        applications::Error::Unavailable | applications::Error::TargetChanged => target_changed(),
        error => application_failure(error),
    })?;
    crate::target::validate_application(target.application, &current, target.window.process)
        .map_err(|_| target_changed())
}

fn execute_with_target(
    action: &ActionRequest,
    cancelled: &AtomicBool,
    target: Option<Target<'_>>,
) -> Option<ActionExecutionReport> {
    let mut run = ActionExecution::new(Plan::for_action(action, Platform::Windows));
    while let Some((id, step)) = run.next_step().expect("native run ordering") {
        if cancelled.load(Ordering::Acquire) {
            return None;
        }
        let start = Instant::now();
        let result = effect(&step.method, cancelled, target);
        run.record(id, result, Some(start.elapsed().as_secs_f64()))
            .expect("finite elapsed duration");
    }
    if cancelled.load(Ordering::Acquire) {
        None
    } else {
        Some(run.report().expect("completed native run"))
    }
}
fn effect(method: &Method, cancelled: &AtomicBool, target: Option<Target<'_>>) -> ActionResult {
    match method {
        Method::KeyEvent {
            key_code,
            modifiers,
        } if (1..=254).contains(key_code) => {
            post(Key::Virtual(*key_code), *modifiers, cancelled, target)
        }
        Method::SystemKey { code } if (1..=254).contains(code) => {
            post(Key::Virtual(*code), 0, cancelled, target)
        }
        Method::KeyboardShortcut { value } => {
            let Some(stroke) = parse_shortcut(value) else {
                return failure(
                    ErrorCode::InvalidInput,
                    "Invalid physical keyboard shortcut",
                    None,
                );
            };
            let Some(key) = input::scan(stroke.usage) else {
                return unsupported();
            };
            if stroke.modifiers & 16 != 0 {
                return unsupported();
            }
            post(key, stroke.modifiers, cancelled, target)
        }
        Method::ToggleDesktop {} => toggle_desktop(cancelled, target),
        Method::OpenUrl { value } => shell_open(value, cancelled, target),
        Method::OpenFolder { value } => {
            let path = std::path::Path::new(value);
            if !path.is_absolute() {
                failure(
                    ErrorCode::InvalidInput,
                    "Windows folders require an absolute path",
                    None,
                )
            } else if !path.is_dir() {
                failure(ErrorCode::NotFound, "Folder does not exist", None)
            } else {
                shell_open(value, cancelled, target)
            }
        }
        Method::LaunchApplication { value } => {
            if let Err(error) = check_target(cancelled, target) {
                return error;
            }
            applications::launch(value, &[])
                .map(|_| ActionResult::success())
                .unwrap_or_else(application_failure)
        }
        // Window close stays on the captured window; application-wide quit has no Windows plan.
        Method::WindowClose {}
        | Method::WindowPlacement { .. }
        | Method::WindowMove { .. }
        | Method::WindowMinimize {} => {
            if let Some(target) = target {
                apply_window_effect(method, target.window, cancelled, Some(target))
            } else {
                foreground_window_effect(
                    method,
                    cancelled,
                    windowing::foreground_window,
                    |method, current| {
                        apply_window_effect(method, current.identity, cancelled, None)
                    },
                )
            }
        }
        Method::LockSession {} => {
            if let Err(error) = check_target(cancelled, target) {
                return error;
            }
            // The API accepts an asynchronous lock request; it does not confirm a locked desktop.
            unsafe {
                SetLastError(0);
                if LockWorkStation() != 0 {
                    ActionResult::success()
                } else {
                    native_failure("Session lock request failed", GetLastError())
                }
            }
        }
        Method::InvalidInput { message } => failure(ErrorCode::InvalidInput, message, None),
        Method::KeyEvent { .. } | Method::SystemKey { .. } => {
            failure(ErrorCode::InvalidInput, "Invalid Windows key code", None)
        }
        _ => unsupported(),
    }
}

fn foreground_window_effect(
    method: &Method,
    cancelled: &AtomicBool,
    query: impl FnOnce() -> Result<windowing::WindowSnapshot, windowing::Error>,
    apply: impl FnOnce(&Method, windowing::WindowSnapshot) -> ActionResult,
) -> ActionResult {
    let current = query();
    if cancelled.load(Ordering::Acquire) {
        return failure(ErrorCode::InternalError, "Execution cancelled", None);
    }
    match current {
        Ok(current) => apply(method, current),
        Err(windowing::Error::Unavailable) => ActionResult::Skipped {
            skip_reason: SkipReason::NoFocusedWindow,
        },
        Err(error) => window_failure(error),
    }
}

fn apply_window_effect(
    method: &Method,
    window: windowing::WindowIdentity,
    cancelled: &AtomicBool,
    target: Option<Target<'_>>,
) -> ActionResult {
    if let Err(error) = check_target(cancelled, target) {
        return error;
    }
    match method {
        Method::WindowClose {} => {
            if window.process == unsafe { GetCurrentProcessId() } {
                return failure(
                    ErrorCode::InvalidInput,
                    "Refusing to close the executor's own window",
                    None,
                );
            }
            windowing::request_close(window)
                .map(|_| ActionResult::success())
                .unwrap_or_else(window_failure)
        }
        Method::WindowMinimize {} => {
            windowing::set_state(window, windowing::WindowState::Minimized)
                .map(|_| ActionResult::success())
                .unwrap_or_else(window_failure)
        }
        Method::WindowPlacement { request } => windowing::place(window, *request, false)
            .map(|_| ActionResult::success())
            .unwrap_or_else(window_failure),
        Method::WindowMove { request } => {
            windowing::move_to_adjacent_display(window, *request, false)
                .map(|_| ActionResult::success())
                .unwrap_or_else(window_failure)
        }
        _ => unreachable!(),
    }
}

#[cfg(test)]
#[path = "foreground_window_tests.rs"]
mod foreground_window_tests;

static INPUT_TRANSACTION: Mutex<()> = Mutex::new(());
fn down(code: u16) -> bool {
    (unsafe { GetAsyncKeyState(code.into()) }) < 0
}
fn post(
    key: Key,
    modifiers: u16,
    cancelled: &AtomicBool,
    expected: Option<Target<'_>>,
) -> ActionResult {
    let _transaction = INPUT_TRANSACTION.lock().unwrap_or_else(|e| e.into_inner());
    if let Err(error) = check_target(cancelled, expected) {
        return error;
    }
    let target = expected
        .map(|target| target.window.handle as usize as HWND)
        .unwrap_or_else(|| unsafe { GetForegroundWindow() });
    if target.is_null() {
        return ActionResult::Skipped {
            skip_reason: SkipReason::NoFrontmostApplication,
        };
    }
    let thread = expected
        .map(|target| target.window.thread)
        .unwrap_or_else(|| unsafe { GetWindowThreadProcessId(target, std::ptr::null_mut()) });
    let layout = unsafe { GetKeyboardLayout(thread) };
    let virtual_key = match key {
        Key::Virtual(code) => code,
        Key::Scan { code, extended } => {
            (unsafe {
                MapVirtualKeyExW(
                    u32::from(code) | if extended { 0xe000 } else { 0 },
                    MAPVK_VSC_TO_VK_EX,
                    layout,
                )
            }) as u16
        }
    };
    if virtual_key == 0 {
        return unsupported();
    }
    let held = u16::from(down(VK_LWIN) || down(VK_RWIN))
        | (u16::from(down(VK_SHIFT)) << 1)
        | (u16::from(down(VK_MENU)) << 2)
        | (u16::from(down(VK_CONTROL)) << 3);
    let events = match input::transaction(key, modifiers, held, down(virtual_key)) {
        Ok(events) => events,
        Err(InputError::InvalidModifiers) => return unsupported(),
        Err(InputError::ConflictingState) => {
            return failure(
                ErrorCode::Busy,
                "Pressed keys conflict with the requested shortcut",
                None,
            );
        }
    };
    if expected.is_some() {
        if let Err(error) = check_target(cancelled, expected) {
            return error;
        }
    } else if target != unsafe { GetForegroundWindow() } {
        return failure(
            ErrorCode::Busy,
            "Foreground window changed before input",
            None,
        );
    }
    if cancelled.load(Ordering::Acquire) {
        return failure(ErrorCode::InternalError, "Execution cancelled", None);
    }
    match input::insert(&events, send) {
        Ok(()) => ActionResult::success(),
        Err(error) => match error.cleanup_error {
            Some(code) => native_failure(
                "Input insertion was partial and key-release recovery could not be completed",
                code,
            ),
            None => native_failure(
                "Input insertion failed; owned partial input was released",
                error.insertion_error,
            ),
        },
    }
}

fn send(events: &[Edge]) -> (usize, u32) {
    let inputs: Vec<INPUT> = events
        .iter()
        .map(|edge| {
            let (vk, scan, flags) = match edge.key {
                Key::Virtual(vk) => (vk, 0, 0),
                Key::Scan { code, extended } => (
                    0,
                    code,
                    KEYEVENTF_SCANCODE | if extended { KEYEVENTF_EXTENDEDKEY } else { 0 },
                ),
            };
            INPUT {
                r#type: INPUT_KEYBOARD,
                Anonymous: INPUT_0 {
                    ki: KEYBDINPUT {
                        wVk: vk,
                        wScan: scan,
                        dwFlags: flags | if edge.up { KEYEVENTF_KEYUP } else { 0 },
                        time: 0,
                        dwExtraInfo: 0,
                    },
                },
            }
        })
        .collect();
    unsafe {
        SetLastError(0);
        let inserted = SendInput(
            inputs.len() as u32,
            inputs.as_ptr(),
            std::mem::size_of::<INPUT>() as i32,
        ) as usize;
        let error = GetLastError();
        (inserted, error)
    }
}
fn shell_open(value: &str, cancelled: &AtomicBool, target: Option<Target<'_>>) -> ActionResult {
    if value.contains('\0') {
        return failure(
            ErrorCode::InvalidInput,
            "Embedded null in workspace input",
            None,
        );
    }
    let wide: Vec<u16> = value.encode_utf16().chain(Some(0)).collect();
    shell_apartment(cancelled, target, move || {
        let mut request = SHELLEXECUTEINFOW {
            cbSize: std::mem::size_of::<SHELLEXECUTEINFOW>() as u32,
            fMask: SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI,
            lpFile: wide.as_ptr(),
            nShow: SW_SHOWNORMAL,
            ..Default::default()
        };
        if unsafe { ShellExecuteExW(&mut request) } == 0 {
            native_failure("Workspace open request failed", unsafe { GetLastError() })
        } else {
            ActionResult::success()
        }
    })
}
fn toggle_desktop(cancelled: &AtomicBool, target: Option<Target<'_>>) -> ActionResult {
    use windows::Win32::{
        Foundation::E_ACCESSDENIED,
        System::Com::{CLSCTX_INPROC_SERVER, CoCreateInstance},
        UI::Shell::{IShellDispatch4, Shell},
    };
    shell_apartment(cancelled, target, || {
        // This is the documented Show Desktop operation; it avoids synthesizing
        // a global Windows-key chord and leaves window restoration to the shell.
        let shell =
            unsafe { CoCreateInstance::<_, IShellDispatch4>(&Shell, None, CLSCTX_INPROC_SERVER) };
        let result = match shell {
            Ok(shell) => {
                if let Err(error) = check_target(cancelled, target) {
                    return error;
                }
                unsafe { shell.ToggleDesktop() }
            }
            Err(error) => Err(error),
        };
        match result {
            Ok(()) => ActionResult::success(),
            Err(error) => failure(
                if error.code() == E_ACCESSDENIED {
                    ErrorCode::AccessDenied
                } else {
                    ErrorCode::NativeFailed
                },
                "Desktop toggle request failed",
                Some(error.code().0.into()),
            ),
        }
    })
}
fn shell_apartment(
    cancelled: &AtomicBool,
    target: Option<Target<'_>>,
    operation: impl FnOnce() -> ActionResult + Send,
) -> ActionResult {
    // Shell operations run in their own STA, never changing the caller's apartment.
    std::thread::scope(|scope| {
        std::thread::Builder::new()
            .spawn_scoped(scope, move || {
                if let Err(error) = check_target(cancelled, target) {
                    return error;
                }
                let status = unsafe {
                    CoInitializeEx(
                        null(),
                        (COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE) as u32,
                    )
                };
                if status < 0 {
                    return failure(
                        ErrorCode::NativeFailed,
                        "Cannot initialize the shell apartment",
                        Some(status.into()),
                    );
                }
                struct Apartment;
                impl Drop for Apartment {
                    fn drop(&mut self) {
                        unsafe { CoUninitialize() }
                    }
                }
                let _apartment = Apartment;
                if let Err(error) = check_target(cancelled, target) {
                    return error;
                }
                operation()
            })
            .map(|worker| {
                worker.join().unwrap_or_else(|_| {
                    failure(ErrorCode::InternalError, "Shell worker failed", None)
                })
            })
            .unwrap_or_else(|error| {
                native_failure(
                    "Cannot start a shell worker",
                    error.raw_os_error().unwrap_or(0) as u32,
                )
            })
    })
}
