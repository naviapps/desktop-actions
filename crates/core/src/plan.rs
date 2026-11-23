use crate::{ActionInput, ActionKind, ActionRequest, ModifierFlags, SystemKey, macos_key_code};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use window_management::{MoveRequest, PlacementRequest};

/// Target adapter. Native key codes in a plan belong only to this platform.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Platform {
    Macos,
    Windows,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Permission {
    Accessibility,
    Automation,
    ScreenRecording,
}
/// Deterministic native instructions. Construction and inspection have no OS effects.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(
    tag = "kind",
    rename_all = "kebab-case",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum Method {
    KeyEvent {
        key_code: u16,
        modifiers: u16,
    },
    SystemKey {
        code: u16,
    },
    KeyboardShortcut {
        value: String,
    },
    AppleScript {
        source: String,
        launches_system_events: bool,
        uses_accessibility: bool,
    },
    OpenUrl {
        value: String,
    },
    OpenFolder {
        value: String,
    },
    LaunchApplication {
        value: String,
    },
    RunShortcut {
        value: String,
    },
    HideFrontmostApplication {},
    TerminateFrontmostApplication {},
    LockSession {},
    ToggleDesktop {},
    ScreenCapture {
        arguments: Vec<String>,
    },
    WindowPlacement {
        request: PlacementRequest,
    },
    WindowMove {
        request: MoveRequest,
    },
    WindowMinimize {},
    WindowClose {},
    WindowToggleFullScreen {},
    InvalidInput {
        message: String,
    },
}
impl Method {
    pub fn permissions(&self, platform: Platform) -> BTreeSet<Permission> {
        if platform == Platform::Windows {
            return BTreeSet::new();
        }
        match self {
            Self::KeyEvent { .. }
            | Self::SystemKey { .. }
            | Self::KeyboardShortcut { .. }
            | Self::WindowPlacement { .. }
            | Self::WindowMove { .. }
            | Self::WindowMinimize {}
            | Self::WindowClose {}
            | Self::WindowToggleFullScreen {} => [Permission::Accessibility].into(),
            Self::AppleScript {
                uses_accessibility, ..
            } => {
                let mut permissions = BTreeSet::from([Permission::Automation]);
                if *uses_accessibility {
                    permissions.insert(Permission::Accessibility);
                }
                permissions
            }
            Self::ScreenCapture { .. } => [Permission::ScreenRecording].into(),
            _ => BTreeSet::new(),
        }
    }
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Step {
    pub method: Method,
    #[serde(default)]
    pub is_fallback: bool,
}
impl Step {
    fn primary(method: Method) -> Self {
        Self {
            method,
            is_fallback: false,
        }
    }
    fn fallback(method: Method) -> Self {
        Self {
            method,
            is_fallback: true,
        }
    }
}
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PermissionSet {
    pub primary: BTreeSet<Permission>,
    pub fallback: BTreeSet<Permission>,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum PermissionReason {
    Accessibility,
    AccessibilityKeyEvent,
    AccessibilityWindowing,
    AutomationAppleEvents,
    ScreenRecordingCapture,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PermissionHint {
    pub permission: Permission,
    pub reason: PermissionReason,
}
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PlanMetadata {
    pub is_executable: bool,
    pub permissions: PermissionSet,
    pub hints: Vec<PermissionHint>,
}
impl PlanMetadata {
    fn for_steps(steps: &[Step], platform: Platform) -> Self {
        let mut result = Self {
            is_executable: !steps.is_empty()
                && steps
                    .iter()
                    .all(|step| !matches!(step.method, Method::InvalidInput { .. })),
            ..Self::default()
        };
        let mut seen = BTreeSet::new();
        for step in steps {
            let permissions = step.method.permissions(platform);
            if step.is_fallback {
                result.permissions.fallback.extend(&permissions);
            } else {
                result.permissions.primary.extend(&permissions);
            }
            for permission in permissions {
                if !seen.insert(permission) {
                    continue;
                }
                let reason = match permission {
                    Permission::Accessibility => match step.method {
                        Method::KeyEvent { .. }
                        | Method::SystemKey { .. }
                        | Method::KeyboardShortcut { .. } => {
                            PermissionReason::AccessibilityKeyEvent
                        }
                        Method::WindowPlacement { .. }
                        | Method::WindowMove { .. }
                        | Method::WindowMinimize {}
                        | Method::WindowClose {}
                        | Method::WindowToggleFullScreen {} => {
                            PermissionReason::AccessibilityWindowing
                        }
                        _ => PermissionReason::Accessibility,
                    },
                    Permission::Automation => PermissionReason::AutomationAppleEvents,
                    Permission::ScreenRecording => PermissionReason::ScreenRecordingCapture,
                };
                result.hints.push(PermissionHint { permission, reason });
            }
        }
        result
    }
}
/// A complete ordered plan. Empty steps mean this platform has no implementation
/// for the requested action; callers must report unsupported rather than success.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Plan {
    pub platform: Platform,
    pub steps: Vec<Step>,
    #[serde(flatten)]
    pub metadata: PlanMetadata,
}
impl Plan {
    pub fn for_action(action: &ActionRequest, platform: Platform) -> Self {
        Self::from_steps(steps(action, platform), platform)
    }
    /// Preview a kind's instructions and permissions using its catalog sample.
    /// The result describes the sample and does not validate any caller input.
    pub fn for_kind(kind: ActionKind, platform: Platform) -> Self {
        Self::for_action(&kind.sample_request(), platform)
    }
    /// Normalize executable values without changing the host's saved action input.
    pub fn from_steps(mut steps: Vec<Step>, platform: Platform) -> Self {
        for step in &mut steps {
            step.method = match &step.method {
                Method::KeyboardShortcut { value } => match crate::parse_shortcut(value) {
                    Some(stroke)
                        if platform == Platform::Windows
                            && stroke.modifiers & ModifierFlags::FUNCTION != 0 =>
                    {
                        // Reject the whole plan, including custom plans with earlier effects.
                        return Self {
                            platform,
                            steps: Vec::new(),
                            metadata: PlanMetadata::default(),
                        };
                    }
                    Some(stroke)
                        if platform == Platform::Windows
                            || crate::macos_key_code(stroke.usage).is_some() =>
                    {
                        step.method.clone()
                    }
                    _ => Method::InvalidInput {
                        message: "Invalid keyboard shortcut for the target platform".into(),
                    },
                },
                Method::OpenUrl { value } => match executable_url(value) {
                    Some(value) => Method::OpenUrl { value },
                    None => Method::InvalidInput {
                        message: "Invalid absolute URL".into(),
                    },
                },
                Method::OpenFolder { value }
                | Method::LaunchApplication { value }
                | Method::RunShortcut { value }
                    if value.trim().is_empty() || value.contains('\0') =>
                {
                    Method::InvalidInput {
                        message: "Invalid workspace or shortcut input".into(),
                    }
                }
                Method::OpenFolder { value } => Method::OpenFolder {
                    value: value.trim().into(),
                },
                Method::LaunchApplication { value } => Method::LaunchApplication {
                    value: value.trim().into(),
                },
                Method::RunShortcut { value } => Method::RunShortcut {
                    value: value.trim().into(),
                },
                _ => step.method.clone(),
            };
        }
        let metadata = PlanMetadata::for_steps(&steps, platform);
        Self {
            platform,
            steps,
            metadata,
        }
    }
}
fn key(code: u16, modifiers: u16) -> Method {
    Method::KeyEvent {
        key_code: code,
        modifiers,
    }
}

fn editing_letter(kind: ActionKind) -> Option<u8> {
    Some(match kind {
        ActionKind::Copy => b'c',
        ActionKind::Paste => b'v',
        ActionKind::Cut => b'x',
        ActionKind::Undo | ActionKind::Redo => b'z',
        ActionKind::SelectAll => b'a',
        ActionKind::FindInApp => b'f',
        _ => return None,
    })
}

/// Logical keyboard target and canonical ANSI stroke for a dedicated macOS
/// editing action. The adapter still resolves the current keyboard layout.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MacosEditingChord {
    pub letter: u8,
    pub key_code: u16,
    pub modifiers: u16,
}

impl MacosEditingChord {
    pub fn for_kind(kind: ActionKind) -> Option<Self> {
        let letter = editing_letter(kind)?;
        Some(Self {
            letter,
            key_code: macos_key_code(u16::from(letter - b'a') + 4)?,
            modifiers: ModifierFlags::META
                | if kind == ActionKind::Redo {
                    ModifierFlags::SHIFT
                } else {
                    0
                },
        })
    }
}

fn script(source: impl Into<String>, uses_accessibility: bool) -> Method {
    Method::AppleScript {
        source: source.into(),
        launches_system_events: true,
        uses_accessibility,
    }
}
fn pair(source: String, fallback: Method) -> Vec<Step> {
    vec![
        Step::primary(script(source, true)),
        Step::fallback(fallback),
    ]
}
fn steps(action: &ActionRequest, platform: Platform) -> Vec<Step> {
    let kind = action.kind();
    let one = |method| vec![Step::primary(method)];
    let mac = platform == Platform::Macos;
    if let Some(control) = SystemKey::for_action(kind) {
        return if let Some(code) = if mac {
            Some(control.macos_code())
        } else {
            control.windows_virtual_key()
        } {
            one(Method::SystemKey { code })
        } else {
            vec![]
        };
    }
    if mac {
        if let Some(chord) = MacosEditingChord::for_kind(kind) {
            return one(key(chord.key_code, chord.modifiers));
        }
    } else if let Some(letter) = editing_letter(kind) {
        let virtual_key = if kind == ActionKind::Redo {
            b'Y'
        } else {
            letter.to_ascii_uppercase()
        };
        return one(key(u16::from(virtual_key), ModifierFlags::CONTROL));
    }
    if let Some(input) = action.input() {
        return one(match input {
            ActionInput::WindowPlacement(request) => Method::WindowPlacement { request: *request },
            ActionInput::WindowMove(request) => Method::WindowMove { request: *request },
            ActionInput::String(value) => match kind {
                ActionKind::KeyboardShortcut => Method::KeyboardShortcut {
                    value: value.clone(),
                },
                ActionKind::OpenURL => Method::OpenUrl {
                    value: value.clone(),
                },
                ActionKind::OpenFolder => Method::OpenFolder {
                    value: value.clone(),
                },
                ActionKind::LaunchApplication => Method::LaunchApplication {
                    value: value.clone(),
                },
                ActionKind::RunShortcut if mac => Method::RunShortcut {
                    value: value.clone(),
                },
                _ => return vec![],
            },
        });
    }
    if kind == ActionKind::QuitFrontmostApplication {
        return if mac {
            one(Method::TerminateFrontmostApplication {})
        } else {
            vec![]
        };
    }
    if kind == ActionKind::CloseForegroundWindow {
        return one(Method::WindowClose {});
    }
    if kind == ActionKind::MinimizeFocusedWindow {
        return one(Method::WindowMinimize {});
    }
    if !mac {
        return match kind {
            ActionKind::ShowWindowOverview => one(key(0x09, 1)),
            ActionKind::ShowDesktop => one(Method::ToggleDesktop {}),
            ActionKind::SwitchToNextVirtualDesktop => one(key(0x27, 9)),
            ActionKind::SwitchToPreviousVirtualDesktop => one(key(0x25, 9)),
            ActionKind::ShowNotificationCenter => one(key(0x4e, 1)),
            ActionKind::CaptureScreenFull => one(key(0x2c, 1)),
            ActionKind::CaptureScreenSelection => one(key(0x53, 3)),
            ActionKind::LockScreen => one(Method::LockSession {}),
            _ => vec![],
        };
    }
    match kind {
        ActionKind::ToggleFocusedWindowFullScreen => one(Method::WindowToggleFullScreen {}),
        ActionKind::HideFrontmostApplication => one(Method::HideFrontmostApplication {}),
        ActionKind::ShowWindowOverview => vec![Step::primary(Method::LaunchApplication { value: "com.apple.exposelauncher".into() }),Step::fallback(key(126, 8))],
        ActionKind::ShowDesktop => pair("tell application \"System Events\" to key code 103".into(),key(103, 16)),
        ActionKind::LockScreen => pair("tell application \"System Events\" to keystroke \"q\" using {control down, command down}".into(),key(12, 9)),
        ActionKind::SwitchToNextVirtualDesktop => pair("tell application \"System Events\" to key code 124 using control down".into(),key(124, 8)),
        ActionKind::SwitchToPreviousVirtualDesktop => pair("tell application \"System Events\" to key code 123 using control down".into(),key(123, 8)),
        ActionKind::MissionControlAppExpose => pair("tell application \"System Events\" to key code 125 using control down".into(),key(125, 8)),
        ActionKind::SleepSystem => one(script("tell application \"System Events\" to sleep",false)),
        ActionKind::ToggleAppearance => one(script("tell application \"System Events\"\n    tell appearance preferences\n        set dark mode to not dark mode\n    end tell\nend tell",false)),
        // An ordinary F8 key event can trigger an unrelated shortcut in the frontmost app.
        ActionKind::ShowNotificationCenter => one(script(
            "tell application \"System Events\"\n    try\n        click menu bar item 1 of menu bar 1 of application process \"NotificationCenter\"\n    on error\n        try\n            click menu bar item 1 of menu bar 1 of application process \"ControlCenter\"\n        on error\n            key code 160\n        end try\n    end try\nend tell",
            true,
        )),
        ActionKind::CaptureScreenFull => one(Method::ScreenCapture { arguments: vec!["-p".into(),"-x".into()] }),
        ActionKind::CaptureScreenSelection => one(Method::ScreenCapture { arguments: vec!["-p".into(),"-i".into()] }),
        ActionKind::CaptureScreenWindow => one(Method::ScreenCapture { arguments: vec!["-p".into(),"-i".into(),"-W".into()] }),
        _ => vec![],
    }
}

fn executable_url(value: &str) -> Option<String> {
    let value = value.trim();
    if value.chars().any(char::is_control) {
        return None;
    }
    let parsed = url::Url::parse(value).ok()?;
    if matches!(parsed.scheme(), "http" | "https") {
        // Reject repaired hostless/backslash HTTP forms before OS-specific URL bridges.
        let authority = value.split_once(':')?.1.strip_prefix("//")?;
        if authority.is_empty()
            || authority.starts_with('/')
            || value.contains('\\')
            || !parsed.has_host()
        {
            return None;
        }
    }
    Some(parsed.into())
}
