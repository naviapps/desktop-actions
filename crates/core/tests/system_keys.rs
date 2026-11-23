use desktop_actions::{ActionKind, SystemKey};

#[test]
fn consumer_controls_use_native_system_namespaces_not_keyboard_positions() {
    let values = [
        (ActionKind::VolumeUp, 0, Some(0xaf)),
        (ActionKind::VolumeDown, 1, Some(0xae)),
        (ActionKind::ToggleAudioMute, 7, Some(0xad)),
        (ActionKind::MediaPlayPause, 16, Some(0xb3)),
        (ActionKind::MediaNext, 17, Some(0xb0)),
        (ActionKind::MediaPrevious, 18, Some(0xb1)),
        (ActionKind::BrightnessUp, 2, None),
        (ActionKind::BrightnessDown, 3, None),
    ];
    for (kind, macos, windows) in values {
        let key = SystemKey::for_action(kind).unwrap();
        assert_eq!(key.macos_code(), macos);
        assert_eq!(key.windows_virtual_key(), windows);
    }
    assert_eq!(SystemKey::for_action(ActionKind::Copy), None);
}
