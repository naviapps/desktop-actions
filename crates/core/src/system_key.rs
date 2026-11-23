use crate::ActionKind;

/// Consumer controls are distinct from physical keyboard positions. In particular,
/// macOS NX key types must never be sent as ordinary CG keyboard key codes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SystemKey {
    VolumeUp,
    VolumeDown,
    ToggleAudioMute,
    PlayPause,
    Next,
    Previous,
    BrightnessUp,
    BrightnessDown,
}
impl SystemKey {
    pub fn for_action(kind: ActionKind) -> Option<Self> {
        Some(match kind {
            ActionKind::VolumeUp => Self::VolumeUp,
            ActionKind::VolumeDown => Self::VolumeDown,
            ActionKind::ToggleAudioMute => Self::ToggleAudioMute,
            ActionKind::MediaPlayPause => Self::PlayPause,
            ActionKind::MediaNext => Self::Next,
            ActionKind::MediaPrevious => Self::Previous,
            ActionKind::BrightnessUp => Self::BrightnessUp,
            ActionKind::BrightnessDown => Self::BrightnessDown,
            _ => return None,
        })
    }
    /// NX_KEYTYPE_* values from IOKit/hidsystem/ev_keymap.h.
    pub fn macos_code(self) -> u16 {
        match self {
            Self::VolumeUp => 0,
            Self::VolumeDown => 1,
            Self::ToggleAudioMute => 7,
            Self::PlayPause => 16,
            Self::Next => 17,
            Self::Previous => 18,
            Self::BrightnessUp => 2,
            Self::BrightnessDown => 3,
        }
    }
    /// VK_VOLUME_* and VK_MEDIA_* values. Windows has no corresponding standard
    /// brightness virtual key; absence must remain an explicit adapter limitation.
    pub fn windows_virtual_key(self) -> Option<u16> {
        Some(match self {
            Self::VolumeUp => 0xaf,
            Self::VolumeDown => 0xae,
            Self::ToggleAudioMute => 0xad,
            Self::PlayPause => 0xb3,
            Self::Next => 0xb0,
            Self::Previous => 0xb1,
            Self::BrightnessUp | Self::BrightnessDown => return None,
        })
    }
}
