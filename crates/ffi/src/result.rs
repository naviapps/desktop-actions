use crate::DesktopActionsJson;
use desktop_actions::{
    ActionError, ActionExecutionReport, ActionResult, Attempt, CodecError, CodecErrorCode,
    ErrorSpec,
};
use serde::{Serialize, de::DeserializeOwned};

fn invalid(message: impl ToString) -> CodecError {
    CodecError {
        code: CodecErrorCode::InvalidData,
        version: None,
        message: message.to_string(),
    }
}
fn canonical<T: DeserializeOwned + Serialize>(bytes: &[u8]) -> Result<Vec<u8>, CodecError> {
    let value: T = serde_json::from_slice(bytes).map_err(invalid)?;
    serde_json::to_vec(&value).map_err(invalid)
}
/// # Safety
/// Input must be readable for length bytes. Kind 0: error, 1: result, 2: attempt,
/// 3: outcome. Original bytes are validated before canonicalization, including
/// duplicate fields and all nested model invariants. No native effects occur.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn desktop_actions_result_normalize(
    data: *const u8,
    length: usize,
    kind: u32,
) -> *mut DesktopActionsJson {
    if data.is_null() || length == 0 || length > isize::MAX as usize {
        return DesktopActionsJson::invalid();
    }
    let bytes = unsafe { std::slice::from_raw_parts(data, length) };
    DesktopActionsJson::result(match kind {
        0 => canonical::<ActionError>(bytes),
        1 => canonical::<ActionResult>(bytes),
        2 => canonical::<Attempt>(bytes),
        3 => canonical::<ActionExecutionReport>(bytes),
        _ => return DesktopActionsJson::invalid(),
    })
}
/// # Safety
/// Input must be readable for length bytes and contain ErrorSpec JSON. Unlike
/// decoding an existing error, this factory supplies blank-message defaults.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn desktop_actions_error_create(
    data: *const u8,
    length: usize,
) -> *mut DesktopActionsJson {
    if data.is_null() || length == 0 || length > isize::MAX as usize {
        return DesktopActionsJson::invalid();
    }
    let bytes = unsafe { std::slice::from_raw_parts(data, length) };
    DesktopActionsJson::result(
        serde_json::from_slice::<ErrorSpec>(bytes)
            .map_err(invalid)
            .and_then(|spec| ActionError::new(spec).map_err(invalid))
            .and_then(|value| serde_json::to_vec(&value).map_err(invalid)),
    )
}
/// # Safety
/// Input must be readable for length bytes and contain an array of valid attempts.
/// The final result is derived in Rust. An empty internal history records an
/// explicit internal failure; decoding an empty serialized outcome remains invalid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn desktop_actions_execution_report_create(
    data: *const u8,
    length: usize,
) -> *mut DesktopActionsJson {
    if data.is_null() || length == 0 || length > isize::MAX as usize {
        return DesktopActionsJson::invalid();
    }
    let bytes = unsafe { std::slice::from_raw_parts(data, length) };
    DesktopActionsJson::result(
        serde_json::from_slice::<Vec<Attempt>>(bytes)
            .map_err(invalid)
            .and_then(|attempts| {
                serde_json::to_vec(&ActionExecutionReport::new(attempts)).map_err(invalid)
            }),
    )
}
