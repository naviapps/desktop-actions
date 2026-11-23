use crate::{ActionKind, InputShape};
use serde::{Deserialize, Deserializer, Serialize, Serializer, de::Error as _};
use serde_json::value::RawValue;
use window_management::{MoveRequest, PlacementRequest};

pub const ENVELOPE_VERSION: i64 = 1;

/// The input attached to an action. Tagged form is used in metadata and language bindings;
/// the action's storage form carries only the value because its kind already determines shape.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(
    tag = "shape",
    content = "value",
    rename_all = "kebab-case",
    deny_unknown_fields
)]
pub enum ActionInput {
    String(String),
    WindowPlacement(PlacementRequest),
    WindowMove(MoveRequest),
}
impl ActionInput {
    /// Decode standalone tagged JSON and normalize it before handing it to a binding.
    pub fn decode(data: &[u8]) -> Result<Self, CodecError> {
        serde_json::from_slice::<Self>(data)
            .map_err(CodecError::json)?
            .normalized()
    }

    pub fn shape(&self) -> InputShape {
        match self {
            Self::String(_) => InputShape::String,
            Self::WindowPlacement(_) => InputShape::WindowPlacement,
            Self::WindowMove(_) => InputShape::WindowMove,
        }
    }
    pub fn normalized(self) -> Result<Self, CodecError> {
        match self {
            Self::String(value) => {
                let value = value.trim();
                if value.is_empty() {
                    Err(CodecError::invalid("String input must not be empty."))
                } else {
                    Ok(Self::String(value.to_owned()))
                }
            }
            Self::WindowPlacement(value) => Ok(Self::WindowPlacement(value.normalized())),
            _ => Ok(self),
        }
    }
}

/// A validated, normalized request. Construction and decoding share the same invariant boundary.
#[derive(Debug, Clone, PartialEq)]
pub struct ActionRequest {
    kind: ActionKind,
    input: Option<ActionInput>,
}
impl ActionRequest {
    pub fn new(kind: ActionKind, input: Option<ActionInput>) -> Result<Self, CodecError> {
        let shape = kind.descriptor().input_descriptor.shape;
        if input.as_ref().map_or(InputShape::None, ActionInput::shape) != shape {
            return Err(CodecError::invalid(
                "ActionRequest input does not match its kind.",
            ));
        }
        Ok(Self {
            kind,
            input: input.map(ActionInput::normalized).transpose()?,
        })
    }
    pub fn kind(&self) -> ActionKind {
        self.kind
    }
    pub fn input(&self) -> Option<&ActionInput> {
        self.input.as_ref()
    }
    pub fn decode(data: &[u8]) -> Result<Self, CodecError> {
        let raw: RawAction = serde_json::from_slice(data).map_err(CodecError::json)?;
        Self::from_raw(raw)
    }
    fn from_raw(raw: RawAction) -> Result<Self, CodecError> {
        let kind = ActionKind::from_identifier(&raw.kind).ok_or_else(|| CodecError {
            code: CodecErrorCode::UnknownAction,
            version: None,
            message: format!("Unknown action identifier: {}", raw.kind),
        })?;
        let input = match (kind.descriptor().input_descriptor.shape, raw.input) {
            (InputShape::None, InputField::Missing) => None,
            (InputShape::String, InputField::Present(value)) => Some(ActionInput::String(
                serde_json::from_str(value.get()).map_err(CodecError::json)?,
            )),
            (InputShape::WindowPlacement, InputField::Present(value)) => {
                Some(ActionInput::WindowPlacement(
                    serde_json::from_str(value.get()).map_err(CodecError::json)?,
                ))
            }
            (InputShape::WindowMove, InputField::Present(value)) => Some(ActionInput::WindowMove(
                serde_json::from_str(value.get()).map_err(CodecError::json)?,
            )),
            _ => {
                return Err(CodecError::invalid(
                    "Required input is missing or unexpected input is present.",
                ));
            }
        };
        Self::new(kind, input)
    }
    pub fn encode(&self) -> Vec<u8> {
        serde_json::to_vec(self).expect("finite normalized action")
    }
    pub fn decode_envelope(data: &[u8]) -> Result<Self, CodecError> {
        let raw: RawEnvelope = serde_json::from_slice(data).map_err(CodecError::json)?;
        if raw.version != ENVELOPE_VERSION {
            return Err(CodecError {
                code: CodecErrorCode::UnsupportedVersion,
                version: Some(raw.version),
                message: format!("Unsupported action envelope version: {}.", raw.version),
            });
        }
        match raw.action {
            InputField::Present(action) => Self::decode(action.get().as_bytes()),
            InputField::Missing => Err(CodecError::invalid("Missing action.")),
        }
    }
    pub fn encode_envelope(&self) -> Vec<u8> {
        #[derive(Serialize)]
        struct Envelope<'a> {
            version: i64,
            action: &'a ActionRequest,
        }
        serde_json::to_vec(&Envelope {
            version: ENVELOPE_VERSION,
            action: self,
        })
        .expect("finite normalized action")
    }
}
impl Serialize for ActionRequest {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeStruct;
        let mut s = serializer
            .serialize_struct("ActionRequest", if self.input.is_some() { 2 } else { 1 })?;
        s.serialize_field("kind", &self.kind.descriptor().identifier)?;
        match &self.input {
            None => (),
            Some(ActionInput::String(v)) => s.serialize_field("input", v)?,
            Some(ActionInput::WindowPlacement(v)) => s.serialize_field("input", v)?,
            Some(ActionInput::WindowMove(v)) => s.serialize_field("input", v)?,
        }
        s.end()
    }
}
impl<'de> Deserialize<'de> for ActionRequest {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Self::from_raw(RawAction::deserialize(deserializer)?).map_err(D::Error::custom)
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawAction {
    kind: String,
    #[serde(default)]
    input: InputField,
}
// Explicit null must remain distinguishable from a missing field, even for input-free actions.
#[derive(Default)]
pub(crate) enum InputField {
    #[default]
    Missing,
    Present(Box<RawValue>),
}
impl<'de> Deserialize<'de> for InputField {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        Box::<RawValue>::deserialize(d).map(Self::Present)
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawEnvelope {
    version: i64,
    #[serde(default)]
    action: InputField,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum CodecErrorCode {
    InvalidData = 1,
    UnsupportedVersion = 2,
    UnknownAction = 3,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CodecError {
    pub code: CodecErrorCode,
    pub version: Option<i64>,
    pub message: String,
}
impl CodecError {
    pub(crate) fn invalid(message: &str) -> Self {
        Self {
            code: CodecErrorCode::InvalidData,
            version: None,
            message: message.into(),
        }
    }
    pub(crate) fn json(error: serde_json::Error) -> Self {
        Self::invalid(&error.to_string())
    }
}
impl std::fmt::Display for CodecError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}
impl std::error::Error for CodecError {}
