use crate::{ActionInput, CodecError, action::InputField};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use std::sync::OnceLock;

/// Typed action names. Persistence uses each descriptor's canonical identifier.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ActionKind {
    Copy,
    Paste,
    Cut,
    Undo,
    Redo,
    SelectAll,
    FindInApp,
    HideFrontmostApplication,
    QuitFrontmostApplication,
    VolumeUp,
    VolumeDown,
    ToggleAudioMute,
    MediaPlayPause,
    MediaNext,
    MediaPrevious,
    KeyboardShortcut,
    #[serde(rename = "openURL")]
    OpenURL,
    LaunchApplication,
    RunShortcut,
    OpenFolder,
    ShowWindowOverview,
    ShowDesktop,
    LockScreen,
    SleepSystem,
    SwitchToNextVirtualDesktop,
    SwitchToPreviousVirtualDesktop,
    MissionControlAppExpose,
    BrightnessUp,
    BrightnessDown,
    ToggleAppearance,
    ShowNotificationCenter,
    CaptureScreenFull,
    CaptureScreenSelection,
    CaptureScreenWindow,
    WindowPlacement,
    WindowMove,
    MinimizeFocusedWindow,
    ToggleFocusedWindowFullScreen,
    CloseForegroundWindow,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum InputShape {
    None,
    String,
    WindowPlacement,
    WindowMove,
}

/// The semantic input form, independent of a host's control layout or localized copy.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum InputForm {
    None,
    Url,
    Application,
    Shortcut,
    KeyboardShortcut,
    Folder,
    WindowPlacement,
    WindowMove,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct InputDescriptor {
    pub shape: InputShape,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parameter: Option<InputParameter>,
}

impl InputDescriptor {
    /// Decode metadata and require an example with the declared shape when input is required.
    pub fn decode(data: &[u8]) -> Result<Self, CodecError> {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct RawDescriptor {
            shape: InputShape,
            #[serde(default)]
            parameter: InputField,
        }
        let raw: RawDescriptor = decode_metadata(data)?;
        Self {
            shape: raw.shape,
            parameter: match raw.parameter {
                InputField::Missing => None,
                InputField::Present(value) => Some(decode_metadata(value.get().as_bytes())?),
            },
        }
        .normalized()
    }

    fn normalized(self) -> Result<Self, CodecError> {
        if self
            .parameter
            .as_ref()
            .map_or(InputShape::None, |parameter| {
                parameter.example_input.shape()
            })
            != self.shape
        {
            return Err(CodecError::invalid(
                "Descriptor metadata must be complete and shape-matched.",
            ));
        }
        Ok(Self {
            shape: self.shape,
            parameter: self.parameter.map(InputParameter::normalized).transpose()?,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct InputParameter {
    pub name: String,
    pub description: String,
    pub example_input: ActionInput,
}
impl InputParameter {
    /// Decode parameter metadata, including the normalized representative input.
    pub fn decode(data: &[u8]) -> Result<Self, CodecError> {
        decode_metadata::<Self>(data)?.normalized()
    }

    fn normalized(self) -> Result<Self, CodecError> {
        Ok(Self {
            name: metadata_label(&self.name)?,
            description: metadata_label(&self.description)?,
            example_input: self.example_input.normalized()?,
        })
    }
}

fn decode_metadata<T: DeserializeOwned>(data: &[u8]) -> Result<T, CodecError> {
    if data.iter().find(|byte| !byte.is_ascii_whitespace()) != Some(&b'{') {
        return Err(CodecError::invalid("Input metadata must be a JSON object."));
    }
    serde_json::from_slice(data).map_err(CodecError::json)
}

fn metadata_label(value: &str) -> Result<String, CodecError> {
    // Preserve the Swift metadata contract, which treated U+200B as whitespace in
    // descriptive labels. Actual action text retains U+200B.
    let trimmed = value.trim_matches(|c: char| c.is_whitespace() || c == '\u{200b}');
    if trimmed.is_empty() {
        return Err(CodecError::invalid(
            "Parameter metadata must be complete and valid.",
        ));
    }
    Ok(trimmed.to_owned())
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum RetryBehavior {
    Safe,
    Unsafe,
    ContextDependent,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Capabilities {
    pub requires_frontmost_application: bool,
    pub requires_focused_window: bool,
    pub requires_interactive_selection: bool,
    pub is_destructive: bool,
    pub retry_behavior: RetryBehavior,
}

/// Shared catalog metadata. OS availability is determined separately by runtime planning.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ActionDescriptor {
    pub name: ActionKind,
    pub identifier: String,
    pub category: String,
    pub input_descriptor: InputDescriptor,
    pub input_form: InputForm,
    pub capabilities: Capabilities,
}

/// Single maintained source for identifiers, input forms, examples and conservative policy hints.
pub fn catalog() -> &'static [ActionDescriptor] {
    static CATALOG: OnceLock<Vec<ActionDescriptor>> = OnceLock::new();
    CATALOG.get_or_init(|| {
        let entries: Vec<ActionDescriptor> =
            serde_json::from_str(include_str!("catalog.json")).expect("valid embedded catalog");
        entries
            .into_iter()
            .map(|mut entry| {
                entry.input_descriptor = entry
                    .input_descriptor
                    .normalized()
                    .expect("valid embedded input descriptor");
                entry
            })
            .collect()
    })
}
impl ActionKind {
    /// Platforms with a plan for this kind's input form. This is not a permission,
    /// installed-target or executor-success check for a caller's actual request.
    pub fn supported_platforms(self) -> Vec<crate::Platform> {
        let action = self.sample_request();
        [crate::Platform::Macos, crate::Platform::Windows]
            .into_iter()
            .filter(|&platform| !crate::Plan::for_action(&action, platform).steps.is_empty())
            .collect()
    }
    pub(crate) fn sample_request(self) -> crate::ActionRequest {
        let input = self
            .descriptor()
            .input_descriptor
            .parameter
            .as_ref()
            .map(|parameter| parameter.example_input.clone());
        crate::ActionRequest::new(self, input).expect("valid catalog input")
    }
    pub fn descriptor(self) -> &'static ActionDescriptor {
        catalog()
            .iter()
            .find(|entry| entry.name == self)
            .expect("complete catalog")
    }
    pub fn from_identifier(identifier: &str) -> Option<Self> {
        catalog()
            .iter()
            .find(|entry| entry.identifier == identifier)
            .map(|entry| entry.name)
    }
}
