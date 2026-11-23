use desktop_actions::{ActionKind, Capabilities, InputShape, RetryBehavior, catalog};

#[test]
fn catalog_keeps_canonical_action_identifiers_and_order() {
    use ActionKind::*;

    let entries = catalog()
        .iter()
        .map(|entry| (entry.name, entry.identifier.as_str()))
        .collect::<Vec<_>>();
    assert_eq!(
        entries,
        [
            (Copy, "action.editing.copy"),
            (Paste, "action.editing.paste"),
            (Cut, "action.editing.cut"),
            (Undo, "action.editing.undo"),
            (Redo, "action.editing.redo"),
            (SelectAll, "action.editing.select-all"),
            (FindInApp, "action.editing.find-in-app"),
            (
                HideFrontmostApplication,
                "action.frontmost-application.hide"
            ),
            (
                QuitFrontmostApplication,
                "action.frontmost-application.quit"
            ),
            (VolumeUp, "action.media.volume-up"),
            (VolumeDown, "action.media.volume-down"),
            (ToggleAudioMute, "action.media.volume-mute"),
            (MediaPlayPause, "action.media.play-pause"),
            (MediaNext, "action.media.next"),
            (MediaPrevious, "action.media.previous"),
            (KeyboardShortcut, "action.keyboard.shortcut"),
            (OpenURL, "action.workspace.open-url"),
            (LaunchApplication, "action.workspace.launch-application"),
            (RunShortcut, "action.workspace.run-shortcut"),
            (OpenFolder, "action.workspace.open-folder"),
            (ShowWindowOverview, "action.system.show-window-overview"),
            (ShowDesktop, "action.system.show-desktop"),
            (LockScreen, "action.system.lock-screen"),
            (SleepSystem, "action.system.sleep-mac"),
            (
                SwitchToNextVirtualDesktop,
                "action.system.switch-to-next-virtual-desktop"
            ),
            (
                SwitchToPreviousVirtualDesktop,
                "action.system.switch-to-previous-virtual-desktop"
            ),
            (
                MissionControlAppExpose,
                "action.system.mission-control-app-expose"
            ),
            (BrightnessUp, "action.system.brightness-up"),
            (BrightnessDown, "action.system.brightness-down"),
            (ToggleAppearance, "action.system.toggle-appearance"),
            (
                ShowNotificationCenter,
                "action.system.show-notification-center"
            ),
            (CaptureScreenFull, "action.system.capture-screen-full"),
            (
                CaptureScreenSelection,
                "action.system.capture-screen-selection"
            ),
            (CaptureScreenWindow, "action.system.capture-screen-window"),
            (WindowPlacement, "action.window.placement"),
            (WindowMove, "action.window.move"),
            (MinimizeFocusedWindow, "action.window.minimize"),
            (
                ToggleFocusedWindowFullScreen,
                "action.window.toggle-full-screen"
            ),
            (CloseForegroundWindow, "action.window.close"),
        ]
    );
}

#[test]
fn catalog_categories_match_their_persistent_identifier_namespaces() {
    for descriptor in catalog() {
        let namespace = descriptor.identifier.split('.').nth(1);
        assert_eq!(
            namespace,
            Some(descriptor.category.as_str()),
            "{}",
            descriptor.identifier
        );
    }
}

#[test]
fn catalog_checks_each_kind_against_its_required_input_shape() {
    use ActionKind::*;

    for descriptor in catalog() {
        let expected = match descriptor.name {
            KeyboardShortcut | OpenURL | LaunchApplication | RunShortcut | OpenFolder => {
                InputShape::String
            }
            WindowPlacement => InputShape::WindowPlacement,
            WindowMove => InputShape::WindowMove,
            _ => InputShape::None,
        };
        assert_eq!(
            descriptor.input_descriptor.shape, expected,
            "{}",
            descriptor.identifier
        );
    }
}

#[test]
fn catalog_capabilities_describe_the_effect_and_its_retry_safety() {
    use ActionKind::*;

    for descriptor in catalog() {
        let kind = descriptor.name;
        let expected = Capabilities {
            requires_frontmost_application: matches!(
                kind,
                Copy | Paste
                    | Cut
                    | Undo
                    | Redo
                    | SelectAll
                    | FindInApp
                    | HideFrontmostApplication
                    | QuitFrontmostApplication
                    | KeyboardShortcut
            ),
            requires_focused_window: matches!(
                kind,
                WindowPlacement
                    | WindowMove
                    | MinimizeFocusedWindow
                    | ToggleFocusedWindowFullScreen
                    | CloseForegroundWindow
            ),
            requires_interactive_selection: matches!(
                kind,
                CaptureScreenSelection | CaptureScreenWindow
            ),
            is_destructive: matches!(
                kind,
                Paste
                    | Cut
                    | Undo
                    | Redo
                    | QuitFrontmostApplication
                    | LockScreen
                    | SleepSystem
                    | ToggleAppearance
                    | CloseForegroundWindow
            ),
            retry_behavior: match kind {
                Copy | SelectAll | FindInApp => RetryBehavior::ContextDependent,
                HideFrontmostApplication | LaunchApplication | WindowPlacement => {
                    RetryBehavior::Safe
                }
                _ => RetryBehavior::Unsafe,
            },
        };
        assert_eq!(
            descriptor.capabilities, expected,
            "{}",
            descriptor.identifier
        );
    }
}
