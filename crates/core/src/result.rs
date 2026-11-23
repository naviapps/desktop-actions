use crate::{Permission, Plan, Platform, Step};
use serde::{Deserialize, Deserializer, Serialize, Serializer, de::Error as _};
use std::collections::BTreeSet;

fn present<'de, D: Deserializer<'de>, T: Deserialize<'de>>(d: D) -> Result<Option<T>, D::Error> {
    T::deserialize(d).map(Some)
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ErrorCode {
    InvalidInput,
    PermissionDenied,
    NotFound,
    OpenFailed,
    AppleScriptFailed,
    ScreenCaptureFailed,
    InternalError,
    UnsupportedAction,
    AccessDenied,
    NativeFailed,
    TimedOut,
    Busy,
}
/// Diagnostic input for an error factory. Optional fields may be omitted, never null.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ErrorSpec {
    pub code: ErrorCode,
    pub diagnostic_message: String,
    #[serde(
        default,
        deserialize_with = "present",
        skip_serializing_if = "Option::is_none"
    )]
    pub permission: Option<Permission>,
    #[serde(
        default,
        deserialize_with = "present",
        skip_serializing_if = "Option::is_none"
    )]
    pub apple_script_error_number: Option<i64>,
    #[serde(
        default,
        deserialize_with = "present",
        skip_serializing_if = "Option::is_none"
    )]
    pub native_code: Option<i64>,
}
/// Validated portable failure. Native codes require the executor's platform context.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(transparent)]
pub struct ActionError(ErrorSpec);
impl ActionError {
    pub fn new(mut spec: ErrorSpec) -> Result<Self, String> {
        if spec.code == ErrorCode::PermissionDenied {
            if spec.permission.is_none() {
                return Err("permission-denied requires permission".into());
            }
            if spec.permission != Some(Permission::Automation)
                && spec.apple_script_error_number.is_some()
            {
                return Err("Only Automation denial accepts an AppleScript error number".into());
            }
        } else if spec.permission.is_some() {
            return Err("This error code does not accept permission".into());
        }
        if spec.apple_script_error_number.is_some()
            && !matches!(
                spec.code,
                ErrorCode::PermissionDenied | ErrorCode::AppleScriptFailed
            )
        {
            return Err("This error code does not accept an AppleScript error number".into());
        }
        if spec.native_code.is_some()
            && !matches!(spec.code, ErrorCode::AccessDenied | ErrorCode::NativeFailed)
        {
            return Err("This error code does not accept a native code".into());
        }
        let message = spec.diagnostic_message.trim();
        spec.diagnostic_message = if message.is_empty() {
            match spec.code {
                ErrorCode::InvalidInput => "Invalid input".into(),
                ErrorCode::PermissionDenied => format!(
                    "Permission denied: {}",
                    match spec.permission.unwrap() {
                        Permission::Accessibility => "accessibility",
                        Permission::Automation => "automation",
                        Permission::ScreenRecording => "screen-recording",
                    }
                ),
                ErrorCode::NotFound => "Not found".into(),
                ErrorCode::OpenFailed => "Open failed".into(),
                ErrorCode::AppleScriptFailed => "AppleScript failed".into(),
                ErrorCode::ScreenCaptureFailed => "Screen capture failed".into(),
                ErrorCode::InternalError => "Internal error".into(),
                ErrorCode::UnsupportedAction => "Unsupported action".into(),
                ErrorCode::AccessDenied => "Native access denied".into(),
                ErrorCode::NativeFailed => "Native operation failed".into(),
                ErrorCode::TimedOut => "ActionRequest timed out".into(),
                ErrorCode::Busy => "Execution capacity is full".into(),
            }
        } else {
            message.into()
        };
        if let Some(number) = spec.apple_script_error_number
            && !spec.diagnostic_message.contains("AppleScript error number")
        {
            spec.diagnostic_message
                .push_str(&format!(" (AppleScript error number {number})"));
        }
        Ok(Self(spec))
    }
    fn simple(code: ErrorCode, message: impl Into<String>) -> Self {
        Self::new(ErrorSpec {
            code,
            diagnostic_message: message.into(),
            permission: None,
            apple_script_error_number: None,
            native_code: None,
        })
        .expect("code without permission")
    }
    pub fn spec(&self) -> &ErrorSpec {
        &self.0
    }
}
impl<'de> Deserialize<'de> for ActionError {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let spec = ErrorSpec::deserialize(d)?;
        if spec.diagnostic_message.trim().is_empty() {
            return Err(D::Error::custom("diagnosticMessage must not be empty"));
        }
        Self::new(spec).map_err(D::Error::custom)
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum SkipReason {
    NoFrontmostApplication,
    NoFocusedWindow,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(
    tag = "status",
    rename_all = "kebab-case",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum ActionResult {
    Success {},
    Skipped { skip_reason: SkipReason },
    Failure { error: ActionError },
}
impl ActionResult {
    pub fn success() -> Self {
        Self::Success {}
    }
    pub fn failure(error: ActionError) -> Self {
        Self::Failure { error }
    }
}
fn valid_duration(value: Option<f64>) -> bool {
    value.is_none_or(|v| v.is_finite() && (0.0..9_223_372_036_854_775_808.0).contains(&v))
}
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Attempt {
    required_permissions: BTreeSet<Permission>,
    is_fallback: bool,
    result: ActionResult,
    #[serde(skip_serializing_if = "Option::is_none")]
    duration_seconds: Option<f64>,
}
impl Attempt {
    pub fn new(
        required_permissions: BTreeSet<Permission>,
        is_fallback: bool,
        result: ActionResult,
        duration_seconds: Option<f64>,
    ) -> Result<Self, String> {
        if !valid_duration(duration_seconds) {
            return Err("durationSeconds must be finite, nonnegative and below 2^63".into());
        }
        Ok(Self {
            required_permissions,
            is_fallback,
            result,
            duration_seconds,
        })
    }
    pub fn result(&self) -> &ActionResult {
        &self.result
    }
    pub fn is_fallback(&self) -> bool {
        self.is_fallback
    }
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RawAttempt {
    required_permissions: Vec<Permission>,
    is_fallback: bool,
    result: ActionResult,
    #[serde(default, deserialize_with = "present")]
    duration_seconds: Option<f64>,
}
impl<'de> Deserialize<'de> for Attempt {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let raw = RawAttempt::deserialize(d)?;
        let permissions: BTreeSet<_> = raw.required_permissions.iter().copied().collect();
        if permissions.len() != raw.required_permissions.len() {
            return Err(D::Error::custom(
                "requiredPermissions must not contain duplicates",
            ));
        }
        Self::new(
            permissions,
            raw.is_fallback,
            raw.result,
            raw.duration_seconds,
        )
        .map_err(D::Error::custom)
    }
}
/// Nonempty recorded outcome. The final result is derived and validated on decode.
#[derive(Debug, Clone, PartialEq)]
pub struct ActionExecutionReport {
    attempts: Vec<Attempt>,
}
impl ActionExecutionReport {
    pub fn new(mut attempts: Vec<Attempt>) -> Self {
        if attempts.is_empty() {
            attempts.push(
                Attempt::new(
                    BTreeSet::new(),
                    false,
                    ActionResult::failure(ActionError::simple(
                        ErrorCode::InternalError,
                        "No execution attempts were recorded",
                    )),
                    None,
                )
                .unwrap(),
            );
        }
        Self { attempts }
    }
    pub fn attempts(&self) -> &[Attempt] {
        &self.attempts
    }
    pub fn final_result(&self) -> &ActionResult {
        &self.attempts.last().expect("nonempty outcome").result
    }
    pub fn did_attempt_fallback(&self) -> bool {
        self.attempts.iter().any(|a| a.is_fallback)
    }
}
impl Serialize for ActionExecutionReport {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        #[derive(Serialize)]
        #[serde(rename_all = "camelCase")]
        struct View<'a> {
            final_result: &'a ActionResult,
            attempts: &'a [Attempt],
        }
        View {
            final_result: self.final_result(),
            attempts: &self.attempts,
        }
        .serialize(s)
    }
}
impl<'de> Deserialize<'de> for ActionExecutionReport {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase", deny_unknown_fields)]
        struct Raw {
            final_result: ActionResult,
            attempts: Vec<Attempt>,
        }
        let raw = Raw::deserialize(d)?;
        if raw.attempts.is_empty() {
            return Err(D::Error::custom("attempts must not be empty"));
        }
        let result = Self {
            attempts: raw.attempts,
        };
        if result.final_result() != &raw.final_result {
            return Err(D::Error::custom(
                "finalResult differs from the last attempt",
            ));
        }
        Ok(result)
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExecutionError {
    StepOutstanding,
    InvalidStep,
    InvalidDuration,
    NotFinished,
}
/// Ordered plan/result reducer. Hosts own native effects and clocks, never fallback
/// selection, permission aggregation or Automation-denial notification policy.
pub struct ActionExecution {
    plan: Plan,
    position: usize,
    awaiting: Option<u64>,
    finished: bool,
    attempts: Vec<Attempt>,
    automation_denied: bool,
    automation_number: Option<i64>,
    last_failure: Option<ActionError>,
}
impl ActionExecution {
    pub fn new(plan: Plan) -> Self {
        Self {
            plan,
            position: 0,
            awaiting: None,
            finished: false,
            attempts: vec![],
            automation_denied: false,
            automation_number: None,
            last_failure: None,
        }
    }
    pub fn next_step(&mut self) -> Result<Option<(u64, Step)>, ExecutionError> {
        if self.awaiting.is_some() {
            return Err(ExecutionError::StepOutstanding);
        }
        if self.finished || self.position >= self.plan.steps.len() {
            self.finished = true;
            return Ok(None);
        }
        let id = self.position as u64 + 1;
        self.awaiting = Some(id);
        Ok(Some((id, self.plan.steps[self.position].clone())))
    }
    pub fn record(
        &mut self,
        id: u64,
        result: ActionResult,
        duration: Option<f64>,
    ) -> Result<(), ExecutionError> {
        if self.awaiting != Some(id) {
            return Err(ExecutionError::InvalidStep);
        }
        let step = &self.plan.steps[self.position];
        let attempt = Attempt::new(
            step.method.permissions(self.plan.platform),
            step.is_fallback,
            result,
            duration,
        )
        .map_err(|_| ExecutionError::InvalidDuration)?;
        match &attempt.result {
            ActionResult::Success {} => self.finished = true,
            ActionResult::Failure { error } => {
                if error.spec().code == ErrorCode::PermissionDenied
                    && error.spec().permission == Some(Permission::Automation)
                {
                    self.automation_denied = true;
                    if error.spec().apple_script_error_number.is_some() {
                        self.automation_number = error.spec().apple_script_error_number;
                    }
                }
                self.last_failure = Some(error.clone());
            }
            ActionResult::Skipped { .. } => {}
        }
        self.attempts.push(attempt);
        self.position += 1;
        self.awaiting = None;
        if self.position == self.plan.steps.len() {
            self.finished = true;
        }
        Ok(())
    }
    pub fn report(&self) -> Result<ActionExecutionReport, ExecutionError> {
        if !self.finished {
            return Err(ExecutionError::NotFinished);
        }
        if self.attempts.is_empty()
            && self.plan.platform == Platform::Windows
            && self.plan.steps.is_empty()
        {
            return Ok(ActionExecutionReport::new(vec![
                Attempt::new(
                    BTreeSet::new(),
                    false,
                    ActionResult::failure(ActionError::simple(
                        ErrorCode::UnsupportedAction,
                        "ActionRequest is unsupported on Windows",
                    )),
                    None,
                )
                .unwrap(),
            ]));
        }
        Ok(ActionExecutionReport::new(self.attempts.clone()))
    }
    /// Some(None) means denial without a native number. Successful fallback and a
    /// final Accessibility denial suppress this callback, matching observed errors.
    pub fn automation_denial(&self) -> Result<Option<Option<i64>>, ExecutionError> {
        if !self.finished {
            return Err(ExecutionError::NotFinished);
        }
        let successful = self
            .attempts
            .last()
            .is_some_and(|a| matches!(a.result, ActionResult::Success {}));
        let accessibility_denied = self.last_failure.as_ref().is_some_and(|e| {
            e.spec().code == ErrorCode::PermissionDenied
                && e.spec().permission == Some(Permission::Accessibility)
        });
        Ok(
            (self.automation_denied && !accessibility_denied && !successful)
                .then_some(self.automation_number),
        )
    }
}
