//! C ABI for desktop action value and bounded execution reducers.
mod result;
mod run;
mod sequence;
mod windows;
use desktop_actions::{
    ActionInput, ActionRequest, CodecError, CodecErrorCode, InputDescriptor, InputParameter,
    catalog, macos_key_code,
};
use desktop_actions::{
    ActionKind, ExecutionPool, KeyStroke, MacosEditingChord, Plan, Platform, Step, SystemKey,
    Terminal, parse_shortcut,
};
use std::sync::Mutex;

/// Native ABI version for the C header and Swift and .NET bindings.
pub const DESKTOP_ACTIONS_ABI_VERSION: u32 = 6u32;

/// Owned immutable UTF-8 JSON or error text. Views are borrowed until destruction.
pub struct DesktopActionsJson {
    code: u32,
    version: Option<i64>,
    data: Vec<u8>,
}
/// Code 0 carries canonical JSON. Codes 1, 2 and 3 carry UTF-8 diagnostic text
/// for invalid data, an unsupported envelope version and an unknown action.
/// Version is meaningful only when has_version is nonzero. Copy bytes before
/// destroying the owner. Callers never free the borrowed data pointer.
#[repr(C)]
pub struct DesktopActionsJsonView {
    pub code: u32,
    pub has_version: u32,
    pub version: i64,
    pub data: *const u8,
    pub length: usize,
}
impl DesktopActionsJson {
    fn result(value: Result<Vec<u8>, CodecError>) -> *mut Self {
        let value = match value {
            Ok(data) => Self {
                code: 0,
                version: None,
                data,
            },
            Err(error) => Self {
                code: error.code as u32,
                version: error.version,
                data: error.message.into_bytes(),
            },
        };
        Box::into_raw(Box::new(value))
    }
    fn invalid() -> *mut Self {
        Box::into_raw(Box::new(Self {
            code: 1,
            version: None,
            data: b"Invalid C input.".to_vec(),
        }))
    }
}
/// The catalog derives supportedPlatforms from Rust plans. Entries do not
/// validate caller input, permissions, installed targets or successful effects.
#[unsafe(no_mangle)]
pub extern "C" fn desktop_actions_catalog() -> *mut DesktopActionsJson {
    #[derive(serde::Serialize)]
    #[serde(rename_all = "camelCase")]
    struct Entry<'a> {
        #[serde(flatten)]
        descriptor: &'a desktop_actions::ActionDescriptor,
        supported_platforms: Vec<Platform>,
    }
    let entries: Vec<_> = catalog()
        .iter()
        .map(|descriptor| Entry {
            descriptor,
            supported_platforms: descriptor.name.supported_platforms(),
        })
        .collect();
    DesktopActionsJson::result(Ok(
        serde_json::to_vec(&entries).expect("valid embedded catalog")
    ))
}
/// The host supplies shortcut catalogs and directory observations for evaluation.
///
/// # Safety
/// Input must be readable for length bytes. This boundary performs no native effects.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn desktop_actions_text_input_evaluate(
    data: *const u8,
    length: usize,
) -> *mut DesktopActionsJson {
    if data.is_null() || length == 0 || length > isize::MAX as usize {
        return DesktopActionsJson::invalid();
    }
    let bytes = unsafe { std::slice::from_raw_parts(data, length) };
    let result = serde_json::from_slice::<desktop_actions::TextInputRequest>(bytes)
        .ok()
        .and_then(|request| request.evaluate())
        .map(|evaluation| serde_json::to_vec(&evaluation).expect("valid input evaluation"));
    match result {
        Some(data) => DesktopActionsJson::result(Ok(data)),
        None => DesktopActionsJson::invalid(),
    }
}

/// # Safety
/// Input must be readable for length bytes. Envelope is zero for a bare action, one for a v1 envelope.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn desktop_actions_action_normalize(
    data: *const u8,
    length: usize,
    envelope: u32,
) -> *mut DesktopActionsJson {
    if data.is_null() || length == 0 || length > isize::MAX as usize || envelope > 1 {
        return DesktopActionsJson::invalid();
    }
    let bytes = unsafe { std::slice::from_raw_parts(data, length) };
    let result = if envelope == 0 {
        ActionRequest::decode(bytes).map(|v| v.encode())
    } else {
        ActionRequest::decode_envelope(bytes).map(|v| v.encode_envelope())
    };
    DesktopActionsJson::result(result)
}
/// # Safety
/// Input must be readable for length bytes and contain tagged ActionInput JSON.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn desktop_actions_input_normalize(
    data: *const u8,
    length: usize,
) -> *mut DesktopActionsJson {
    if data.is_null() || length == 0 || length > isize::MAX as usize {
        return DesktopActionsJson::invalid();
    }
    let bytes = unsafe { std::slice::from_raw_parts(data, length) };
    let result =
        ActionInput::decode(bytes).map(|v| serde_json::to_vec(&v).expect("normalized input"));
    DesktopActionsJson::result(result)
}
/// # Safety
/// Input must be readable for length bytes. Kind is zero for an input parameter
/// and one for an input descriptor.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn desktop_actions_input_metadata_normalize(
    data: *const u8,
    length: usize,
    kind: u32,
) -> *mut DesktopActionsJson {
    if data.is_null() || length == 0 || length > isize::MAX as usize {
        return DesktopActionsJson::invalid();
    }
    let bytes = unsafe { std::slice::from_raw_parts(data, length) };
    let result = match kind {
        0 => InputParameter::decode(bytes)
            .map(|value| serde_json::to_vec(&value).expect("normalized input parameter")),
        1 => InputDescriptor::decode(bytes)
            .map(|value| serde_json::to_vec(&value).expect("normalized input descriptor")),
        _ => return DesktopActionsJson::invalid(),
    };
    DesktopActionsJson::result(result)
}
fn platform(value: u32) -> Option<Platform> {
    match value {
        0 => Some(Platform::Macos),
        1 => Some(Platform::Windows),
        _ => None,
    }
}
/// Platform 0 selects macOS and 1 selects Windows. An empty step array means
/// the action is unsupported on the selected platform.
///
/// # Safety
/// Input must be readable for length bytes and contain a bare action. Planning
/// never queries permissions, launches processes or posts input.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn desktop_actions_action_plan(
    data: *const u8,
    length: usize,
    target: u32,
) -> *mut DesktopActionsJson {
    let Some(platform) = platform(target) else {
        return DesktopActionsJson::invalid();
    };
    if data.is_null() || length == 0 || length > isize::MAX as usize {
        return DesktopActionsJson::invalid();
    }
    let bytes = unsafe { std::slice::from_raw_parts(data, length) };
    DesktopActionsJson::result(ActionRequest::decode(bytes).map(|action| {
        serde_json::to_vec(&Plan::for_action(&action, platform)).expect("finite native plan")
    }))
}
/// # Safety
/// The UTF-8 catalog identifier must be readable for length bytes.
/// Returns the same plan shape as action planning, using the catalog sample.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn desktop_actions_action_kind_plan(
    data: *const u8,
    length: usize,
    target: u32,
) -> *mut DesktopActionsJson {
    let Some(platform) = platform(target) else {
        return DesktopActionsJson::invalid();
    };
    if data.is_null() || length == 0 || length > isize::MAX as usize {
        return DesktopActionsJson::invalid();
    }
    let bytes = unsafe { std::slice::from_raw_parts(data, length) };
    let Ok(identifier) = std::str::from_utf8(bytes) else {
        return DesktopActionsJson::invalid();
    };
    let result = ActionKind::from_identifier(identifier)
        .map(|kind| {
            serde_json::to_vec(&Plan::for_kind(kind, platform)).expect("finite catalog plan")
        })
        .ok_or_else(|| CodecError {
            code: CodecErrorCode::UnknownAction,
            version: None,
            message: "Unknown action identifier.".into(),
        });
    DesktopActionsJson::result(result)
}

#[repr(C)]
#[derive(Default)]
pub struct DesktopActionsMacosEditingChord {
    pub letter: u16,
    pub key_code: u16,
    pub modifiers: u16,
}

/// Returns the lowercase ASCII letter and canonical macOS stroke of a dedicated
/// editing action. Invalid identifiers and other actions return zero fields.
///
/// # Safety
/// The UTF-8 catalog identifier must be readable for length bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn desktop_actions_macos_editing_chord(
    data: *const u8,
    length: usize,
) -> DesktopActionsMacosEditingChord {
    if data.is_null() || length == 0 || length > isize::MAX as usize {
        return DesktopActionsMacosEditingChord::default();
    }
    let bytes = unsafe { std::slice::from_raw_parts(data, length) };
    std::str::from_utf8(bytes)
        .ok()
        .and_then(ActionKind::from_identifier)
        .and_then(MacosEditingChord::for_kind)
        .map_or_else(DesktopActionsMacosEditingChord::default, |chord| {
            DesktopActionsMacosEditingChord {
                letter: u16::from(chord.letter),
                key_code: chord.key_code,
                modifiers: chord.modifiers,
            }
        })
}

/// # Safety
/// Input must be readable for length bytes and contain an array of tagged plan
/// steps. Only permission metadata is returned; no instruction is executed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn desktop_actions_plan_metadata(
    data: *const u8,
    length: usize,
    target: u32,
) -> *mut DesktopActionsJson {
    let Some(platform) = platform(target) else {
        return DesktopActionsJson::invalid();
    };
    if data.is_null() || length == 0 || length > isize::MAX as usize {
        return DesktopActionsJson::invalid();
    }
    let bytes = unsafe { std::slice::from_raw_parts(data, length) };
    let result = serde_json::from_slice::<Vec<Step>>(bytes)
        .map_err(|error| CodecError {
            code: CodecErrorCode::InvalidData,
            version: None,
            message: error.to_string(),
        })
        .map(|steps| {
            serde_json::to_vec(&Plan::from_steps(steps, platform).metadata)
                .expect("native plan metadata")
        });
    DesktopActionsJson::result(result)
}
/// # Safety
/// Owner must be live for this call and for all uses of returned bytes. Null produces an empty error view.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn desktop_actions_json_view(
    owner: *const DesktopActionsJson,
) -> DesktopActionsJsonView {
    match unsafe { owner.as_ref() } {
        Some(value) => DesktopActionsJsonView {
            code: value.code,
            has_version: u32::from(value.version.is_some()),
            version: value.version.unwrap_or(0),
            data: value.data.as_ptr(),
            length: value.data.len(),
        },
        None => DesktopActionsJsonView {
            code: 1,
            has_version: 0,
            version: 0,
            data: std::ptr::null(),
            length: 0,
        },
    }
}
/// # Safety
/// Owner must be null or exclusively owned, with no live views or concurrent calls remaining.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn desktop_actions_json_destroy(owner: *mut DesktopActionsJson) {
    if !owner.is_null() {
        drop(unsafe { Box::from_raw(owner) });
    }
}
/// Returns -1 when the physical usage has no supported macOS ANSI key mapping.
#[unsafe(no_mangle)]
pub extern "C" fn desktop_actions_macos_key_code(usage: u16) -> i32 {
    macos_key_code(usage).map_or(-1, i32::from)
}
/// Returns -1 for an unknown action or unsupported mapping.
///
/// # Safety
/// The canonical action identifier must be readable for length bytes. Platform 0
/// selects macOS NX keys, 1 selects Windows virtual keys. No input is posted.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn desktop_actions_system_key(
    data: *const u8,
    length: usize,
    platform: u32,
) -> i32 {
    if data.is_null() || length == 0 || length > isize::MAX as usize {
        return -1;
    }
    let bytes = unsafe { std::slice::from_raw_parts(data, length) };
    let key = std::str::from_utf8(bytes)
        .ok()
        .and_then(ActionKind::from_identifier)
        .and_then(SystemKey::for_action);
    key.and_then(|key| match platform {
        0 => Some(key.macos_code()),
        1 => key.windows_virtual_key(),
        _ => None,
    })
    .map_or(-1, i32::from)
}
#[unsafe(no_mangle)]
pub extern "C" fn desktop_actions_abi_version() -> u32 {
    DESKTOP_ACTIONS_ABI_VERSION
}
#[repr(C)]
pub struct DesktopActionsKeyStroke {
    pub usage: u16,
    pub modifiers: u16,
}
impl From<KeyStroke> for DesktopActionsKeyStroke {
    fn from(stroke: KeyStroke) -> Self {
        Self {
            usage: stroke.usage,
            modifiers: stroke.modifiers,
        }
    }
}
#[repr(C)]
pub struct DesktopActionsKeyResult {
    pub code: u32,
    pub stroke: DesktopActionsKeyStroke,
}
/// # Safety
/// UTF-8 input must be null for zero length or readable/aligned for length bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn desktop_actions_parse_shortcut(
    data: *const u8,
    length: usize,
) -> DesktopActionsKeyResult {
    let invalid = || DesktopActionsKeyResult {
        code: 1,
        stroke: DesktopActionsKeyStroke {
            usage: 0,
            modifiers: 0,
        },
    };
    if length == 0 || length > isize::MAX as usize || data.is_null() {
        return invalid();
    }
    let value = unsafe { std::slice::from_raw_parts(data, length) };
    std::str::from_utf8(value)
        .ok()
        .and_then(parse_shortcut)
        .map_or_else(invalid, |stroke| DesktopActionsKeyResult {
            code: 0,
            stroke: stroke.into(),
        })
}
/// Owned execution pool. Terminal codes are 0 for no delivery, 1 for completed,
/// 2 for cancelled and 3 for timed out.
pub struct DesktopActionsExecutionPool(Mutex<ExecutionPool>);

/// The maximum and timeout in nanoseconds must both be positive. Invalid policy
/// returns null.
#[unsafe(no_mangle)]
pub extern "C" fn desktop_actions_execution_create(
    maximum: usize,
    timeout_ns: u64,
) -> *mut DesktopActionsExecutionPool {
    ExecutionPool::new(maximum, timeout_ns).map_or(std::ptr::null_mut(), |pool| {
        Box::into_raw(Box::new(DesktopActionsExecutionPool(Mutex::new(pool))))
    })
}
/// # Safety
/// Pool must be live; concurrent calls are serialized internally. No callbacks occur under lock.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn desktop_actions_execution_reserve(
    pool: *const DesktopActionsExecutionPool,
    now_ns: u64,
    interactive: u32,
) -> u64 {
    unsafe { pool.as_ref() }
        .and_then(|p| {
            p.0.lock()
                .unwrap_or_else(|e| e.into_inner())
                .reserve(now_ns, interactive != 0)
        })
        .unwrap_or(0)
}
/// # Safety
/// Pool must be live. The deadline is in nanoseconds. Zero means no deadline
/// (interactive or already terminal).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn desktop_actions_execution_deadline(
    pool: *const DesktopActionsExecutionPool,
    id: u64,
) -> u64 {
    unsafe { pool.as_ref() }
        .and_then(|p| p.0.lock().unwrap_or_else(|e| e.into_inner()).deadline(id))
        .unwrap_or(0)
}
/// # Safety
/// Pool must be live. Returns a winning terminal code: 0 none, 2 cancelled,
/// 3 timed out. Capacity remains held until actual worker completion.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn desktop_actions_execution_cancel(
    pool: *const DesktopActionsExecutionPool,
    id: u64,
    now_ns: u64,
) -> u32 {
    unsafe { pool.as_ref() }
        .and_then(|p| {
            p.0.lock()
                .unwrap_or_else(|e| e.into_inner())
                .cancel(id, now_ns)
        })
        .map_or(0, |terminal| terminal as u32)
}
/// # Safety
/// Pool must be live. Returns 3 only when timeout claims terminal delivery.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn desktop_actions_execution_timeout(
    pool: *const DesktopActionsExecutionPool,
    id: u64,
    now_ns: u64,
) -> u32 {
    if unsafe { pool.as_ref() }.is_some_and(|p| {
        p.0.lock()
            .unwrap_or_else(|e| e.into_inner())
            .timeout(id, now_ns)
    }) {
        Terminal::TimedOut as u32
    } else {
        0
    }
}
/// # Safety
/// Pool must be live. One means terminal delivery has not yet been claimed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn desktop_actions_execution_active(
    pool: *const DesktopActionsExecutionPool,
    id: u64,
) -> u32 {
    u32::from(
        unsafe { pool.as_ref() }
            .is_some_and(|p| p.0.lock().unwrap_or_else(|e| e.into_inner()).is_active(id)),
    )
}
/// # Safety
/// Pool must be live. Releases actual worker capacity once. Returns 0 for a prior
/// delivery/missing id, 1 for completion, 3 for completion at or after its deadline.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn desktop_actions_execution_finish(
    pool: *const DesktopActionsExecutionPool,
    id: u64,
    now_ns: u64,
) -> u32 {
    unsafe { pool.as_ref() }
        .and_then(|p| {
            p.0.lock()
                .unwrap_or_else(|e| e.into_inner())
                .finish(id, now_ns)
        })
        .map_or(0, |terminal| terminal as u32)
}
/// # Safety
/// Pool must be null or exclusively owned; no concurrent calls may be in progress.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn desktop_actions_execution_destroy(pool: *mut DesktopActionsExecutionPool) {
    if !pool.is_null() {
        drop(unsafe { Box::from_raw(pool) })
    }
}
