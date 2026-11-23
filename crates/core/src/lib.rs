//! Shared desktop action values, validation, input planning and bounded execution state.
mod action;
mod catalog;
mod execution;
mod keyboard;
mod plan;
mod result;
mod sequence;
mod system_key;
mod text_input;
pub use action::{ActionInput, ActionRequest, CodecError, CodecErrorCode, ENVELOPE_VERSION};
pub use catalog::{
    ActionDescriptor, ActionKind, Capabilities, InputDescriptor, InputForm, InputParameter,
    InputShape, RetryBehavior, catalog,
};
pub use execution::{ExecutionId, ExecutionPool, Terminal};
pub use keyboard::{KeyStroke, ModifierFlags, macos_key_code, parse_shortcut};
pub use plan::{
    MacosEditingChord, Method, Permission, PermissionHint, PermissionReason, PermissionSet, Plan,
    PlanMetadata, Platform, Step,
};
pub use result::{
    ActionError, ActionExecution, ActionExecutionReport, ActionResult, Attempt, ErrorCode,
    ErrorSpec, ExecutionError, SkipReason,
};
pub use sequence::{ActionSequence, SequenceActionResult, SequenceFailureBehavior, SequenceStatus};
pub use system_key::SystemKey;

pub use text_input::{TextInputEvaluation, TextInputIssue, TextInputRequest};
