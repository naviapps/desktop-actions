use desktop_actions::{
    ActionExecution, ActionInput, ActionKind, ActionRequest, ActionResult, ErrorCode,
    MacosEditingChord, Method, ModifierFlags, Permission, PermissionHint, PermissionReason, Plan,
    Platform, RetryBehavior, Step, catalog,
};

#[test]
fn catalog_previews_match_sample_requests_on_each_platform() {
    for entry in catalog() {
        let input = entry
            .input_descriptor
            .parameter
            .as_ref()
            .map(|p| p.example_input.clone());
        let action = ActionRequest::new(entry.name, input).unwrap();
        for platform in [Platform::Macos, Platform::Windows] {
            let preview = Plan::for_kind(entry.name, platform);
            assert_eq!(preview, Plan::for_action(&action, platform));
            assert_eq!(
                !preview.steps.is_empty(),
                entry.name.supported_platforms().contains(&platform),
                "{}",
                entry.identifier
            );
            if platform == Platform::Macos {
                assert!(!preview.steps.is_empty(), "{}", entry.identifier);
            }
            serde_json::to_vec(&preview).unwrap();
        }
    }
}

#[test]
fn unavailable_windows_operations_produce_no_plan_steps() {
    for kind in [
        ActionKind::BrightnessUp,
        ActionKind::SleepSystem,
        ActionKind::RunShortcut,
    ] {
        let input = kind
            .descriptor()
            .input_descriptor
            .parameter
            .as_ref()
            .map(|p| p.example_input.clone());
        assert!(
            Plan::for_action(&ActionRequest::new(kind, input).unwrap(), Platform::Windows)
                .steps
                .is_empty()
        );
    }
}

#[test]
fn dedicated_select_all_and_find_in_app_keep_distinct_wire_forms_from_raw_shortcuts() {
    for (kind, identifier, raw_shortcut) in [
        (ActionKind::SelectAll, "action.editing.select-all", "cmd+a"),
        (ActionKind::FindInApp, "action.editing.find-in-app", "cmd+f"),
    ] {
        let action = ActionRequest::new(kind, None).unwrap();
        let envelope = action.encode_envelope();
        assert_eq!(
            serde_json::from_slice::<serde_json::Value>(&envelope).unwrap(),
            serde_json::json!({"version": 1, "action": {"kind": identifier}})
        );
        assert_eq!(ActionRequest::decode_envelope(&envelope).unwrap(), action);
        let raw_action = ActionRequest::new(
            ActionKind::KeyboardShortcut,
            Some(ActionInput::String(raw_shortcut.into())),
        )
        .unwrap();
        let raw_plan = Plan::for_action(&raw_action, Platform::Macos);
        let [raw_step] = raw_plan.steps.as_slice() else {
            panic!("{raw_shortcut} must retain its physical shortcut step");
        };
        assert_eq!(
            raw_step.method,
            Method::KeyboardShortcut {
                value: raw_shortcut.into()
            }
        );
    }
}

#[test]
fn logical_editing_keys_keep_their_native_strokes_and_permissions() {
    for (kind, letter, mac_key, windows_key, mac_modifiers) in [
        (ActionKind::Copy, b'c', 8, b'C', ModifierFlags::META),
        (ActionKind::Paste, b'v', 9, b'V', ModifierFlags::META),
        (ActionKind::Cut, b'x', 7, b'X', ModifierFlags::META),
        (ActionKind::Undo, b'z', 6, b'Z', ModifierFlags::META),
        (
            ActionKind::Redo,
            b'z',
            6,
            b'Y',
            ModifierFlags::META | ModifierFlags::SHIFT,
        ),
        (ActionKind::SelectAll, b'a', 0, b'A', ModifierFlags::META),
        (ActionKind::FindInApp, b'f', 3, b'F', ModifierFlags::META),
    ] {
        assert_eq!(
            MacosEditingChord::for_kind(kind),
            Some(MacosEditingChord {
                letter,
                key_code: mac_key,
                modifiers: mac_modifiers,
            })
        );
        for (platform, key_code, modifiers, primary) in [
            (
                Platform::Macos,
                mac_key,
                mac_modifiers,
                [Permission::Accessibility].into_iter().collect(),
            ),
            (
                Platform::Windows,
                u16::from(windows_key),
                ModifierFlags::CONTROL,
                Default::default(),
            ),
        ] {
            let plan = Plan::for_kind(kind, platform);
            assert_eq!(
                plan.steps,
                [Step {
                    method: Method::KeyEvent {
                        key_code,
                        modifiers,
                    },
                    is_fallback: false,
                }]
            );
            assert!(plan.metadata.is_executable);
            assert_eq!(plan.metadata.permissions.primary, primary);
            assert!(plan.metadata.permissions.fallback.is_empty());
        }
    }
    for entry in catalog() {
        assert_eq!(
            MacosEditingChord::for_kind(entry.name).is_some(),
            entry.category == "editing",
            "{}",
            entry.identifier
        );
    }
}

#[test]
fn executable_metadata_uses_target_keyboard_validation_without_native_effects() {
    for (shortcut, platform, executable) in [
        ("cmd+shift+p", Platform::Macos, true),
        ("cmd++c", Platform::Macos, false),
        ("f24", Platform::Macos, false),
        ("fn+f11", Platform::Macos, true),
        ("f11", Platform::Windows, true),
        ("ctrl+f24", Platform::Windows, true),
        ("cmd++c", Platform::Windows, false),
    ] {
        let action = ActionRequest::new(
            ActionKind::KeyboardShortcut,
            Some(ActionInput::String(shortcut.into())),
        )
        .unwrap();
        let plan = Plan::for_action(&action, platform);
        assert_eq!(
            plan.metadata.is_executable, executable,
            "{shortcut} {platform:?}"
        );
        if !executable {
            assert!(matches!(plan.steps[0].method, Method::InvalidInput { .. }));
            assert!(plan.metadata.permissions.primary.is_empty());
        }
    }
    let unsupported = ActionRequest::new(ActionKind::SleepSystem, None).unwrap();
    assert!(
        !Plan::for_action(&unsupported, Platform::Windows)
            .metadata
            .is_executable
    );
}

#[test]
fn unsupported_windows_function_modifier_never_claims_an_execution_step() {
    for shortcut in ["fn+f11", "FUNCTION+ctrl+f11", "fn-forward-delete", "fn+f24"] {
        let action = ActionRequest::new(
            ActionKind::KeyboardShortcut,
            Some(ActionInput::String(shortcut.into())),
        )
        .unwrap();
        let plan = Plan::for_action(&action, Platform::Windows);
        assert!(plan.steps.is_empty(), "{shortcut}");
        assert!(!plan.metadata.is_executable, "{shortcut}");
        let mut run = ActionExecution::new(plan);
        assert!(run.next_step().unwrap().is_none(), "{shortcut}");
        let report = run.report().unwrap();
        assert!(matches!(
            report.final_result(),
            ActionResult::Failure { error } if error.spec().code == ErrorCode::UnsupportedAction
        ));
    }
}

#[test]
fn unsupported_windows_shortcut_rejects_the_whole_custom_plan() {
    let steps: Vec<Step> = serde_json::from_slice(
        br#"[{"method":{"kind":"keyboard-shortcut","value":"ctrl+c"},"isFallback":false},
             {"method":{"kind":"keyboard-shortcut","value":"fn+f11"},"isFallback":true}]"#,
    )
    .unwrap();
    let windows = Plan::from_steps(steps.clone(), Platform::Windows);
    assert!(windows.steps.is_empty());
    assert!(!windows.metadata.is_executable);
    let mut run = ActionExecution::new(windows);
    assert!(run.next_step().unwrap().is_none());
    let error = serde_json::json!({
        "status":"failure",
        "error":{"code":"unsupported-action","diagnosticMessage":"ActionRequest is unsupported on Windows"}
    });
    assert_eq!(
        serde_json::to_value(run.report().unwrap()).unwrap(),
        serde_json::json!({
            "finalResult":error,
            "attempts":[{"requiredPermissions":[],"isFallback":false,"result":error}]
        })
    );
    assert_eq!(run.automation_denial().unwrap(), None);

    let macos = Plan::from_steps(steps, Platform::Macos);
    assert!(macos.metadata.is_executable);
    assert_eq!(macos.steps.len(), 2);
}

#[test]
fn system_scripts_precede_their_native_key_fallbacks_with_ordered_permissions() {
    for (kind, snippet, key_code, modifiers) in [
        (
            ActionKind::ShowDesktop,
            "key code 103",
            103,
            ModifierFlags::FUNCTION,
        ),
        (
            ActionKind::LockScreen,
            r#"keystroke "q""#,
            12,
            ModifierFlags::CONTROL | ModifierFlags::META,
        ),
        (
            ActionKind::SwitchToNextVirtualDesktop,
            "key code 124 using control down",
            124,
            ModifierFlags::CONTROL,
        ),
        (
            ActionKind::SwitchToPreviousVirtualDesktop,
            "key code 123 using control down",
            123,
            ModifierFlags::CONTROL,
        ),
        (
            ActionKind::MissionControlAppExpose,
            "key code 125 using control down",
            125,
            ModifierFlags::CONTROL,
        ),
    ] {
        let action = ActionRequest::new(kind, None).unwrap();
        let plan = Plan::for_action(&action, Platform::Macos);
        let [primary, fallback] = plan.steps.as_slice() else {
            panic!("{kind:?} requires a script followed by a key event fallback");
        };
        assert!(!primary.is_fallback, "{kind:?}");
        assert!(fallback.is_fallback, "{kind:?}");
        assert!(
            matches!(
                &primary.method,
                Method::AppleScript {
                    source,
                    launches_system_events: true,
                    uses_accessibility: true,
                } if source.contains("System Events") && source.contains(snippet)
            ),
            "{kind:?}"
        );
        assert_eq!(
            fallback.method,
            Method::KeyEvent {
                key_code,
                modifiers
            },
            "{kind:?}"
        );
        let primary_permissions = [Permission::Accessibility, Permission::Automation].into();
        let fallback_permissions = [Permission::Accessibility].into();
        assert_eq!(
            primary.method.permissions(Platform::Macos),
            primary_permissions,
            "{kind:?}"
        );
        assert_eq!(
            fallback.method.permissions(Platform::Macos),
            fallback_permissions,
            "{kind:?}"
        );
        assert_eq!(
            plan.metadata.permissions.primary, primary_permissions,
            "{kind:?}"
        );
        assert_eq!(
            plan.metadata.permissions.fallback, fallback_permissions,
            "{kind:?}"
        );
        assert_eq!(
            plan.metadata.hints,
            [
                PermissionHint {
                    permission: Permission::Accessibility,
                    reason: PermissionReason::Accessibility,
                },
                PermissionHint {
                    permission: Permission::Automation,
                    reason: PermissionReason::AutomationAppleEvents,
                },
            ],
            "{kind:?}"
        );
    }
}

#[test]
fn macos_window_overview_launches_before_its_key_fallback() {
    let action = ActionRequest::new(ActionKind::ShowWindowOverview, None).unwrap();
    let plan = Plan::for_action(&action, Platform::Macos);
    let [primary, fallback] = plan.steps.as_slice() else {
        panic!("Window overview requires native application launch followed by a key event");
    };
    assert!(!primary.is_fallback);
    assert!(fallback.is_fallback);
    assert_eq!(
        primary.method,
        Method::LaunchApplication {
            value: "com.apple.exposelauncher".into(),
        }
    );
    assert_eq!(
        fallback.method,
        Method::KeyEvent {
            key_code: 126,
            modifiers: ModifierFlags::CONTROL,
        }
    );
    assert!(plan.metadata.permissions.primary.is_empty());
    assert_eq!(
        plan.metadata.permissions.fallback,
        [Permission::Accessibility].into()
    );
    assert_eq!(
        fallback.method.permissions(Platform::Macos),
        plan.metadata.permissions.fallback
    );
}

#[test]
fn macos_appearance_and_sleep_scripts_require_only_automation() {
    for (kind, snippet) in [
        (ActionKind::ToggleAppearance, "appearance preferences"),
        (ActionKind::SleepSystem, "sleep"),
    ] {
        let action = ActionRequest::new(kind, None).unwrap();
        let plan = Plan::for_action(&action, Platform::Macos);
        let [step] = plan.steps.as_slice() else {
            panic!("{kind:?} requires one script");
        };
        assert!(!step.is_fallback, "{kind:?}");
        assert!(
            matches!(
                &step.method,
                Method::AppleScript {
                    source,
                    launches_system_events: true,
                    uses_accessibility: false,
                } if source.contains("System Events") && source.contains(snippet)
            ),
            "{kind:?}"
        );
        assert_eq!(
            plan.metadata.permissions.primary,
            [Permission::Automation].into(),
            "{kind:?}"
        );
        assert!(plan.metadata.permissions.fallback.is_empty(), "{kind:?}");
    }
}

#[test]
fn macos_screen_capture_plans_select_arguments_and_permission_by_mode() {
    for (kind, args) in [
        (ActionKind::CaptureScreenFull, &["-p", "-x"][..]),
        (ActionKind::CaptureScreenSelection, &["-p", "-i"][..]),
        (ActionKind::CaptureScreenWindow, &["-p", "-i", "-W"][..]),
    ] {
        let action = ActionRequest::new(kind, None).unwrap();
        let plan = Plan::for_action(&action, Platform::Macos);
        let [step] = plan.steps.as_slice() else {
            panic!("expected one native capture operation");
        };
        assert_eq!(
            step.method,
            Method::ScreenCapture {
                arguments: args.iter().map(|arg| (*arg).into()).collect(),
            }
        );
        assert!(!step.is_fallback);
        assert_eq!(
            step.method.permissions(Platform::Macos),
            [Permission::ScreenRecording].into()
        );
        assert_eq!(
            plan.metadata.permissions.primary,
            [Permission::ScreenRecording].into()
        );
        assert!(plan.metadata.permissions.fallback.is_empty());
        assert_eq!(
            plan.metadata.hints,
            [PermissionHint {
                permission: Permission::ScreenRecording,
                reason: PermissionReason::ScreenRecordingCapture,
            }]
        );
    }
}

#[test]
fn notification_center_uses_only_the_macos_script() {
    let action = ActionRequest::new(ActionKind::ShowNotificationCenter, None).unwrap();
    let plan = Plan::for_action(&action, Platform::Macos);
    let [step] = plan.steps.as_slice() else {
        panic!("Notification Center must not fall back to an ordinary F8 key event");
    };
    assert!(matches!(
        &step.method,
        Method::AppleScript {
            launches_system_events: true,
            uses_accessibility: true,
            ..
        }
    ));
    assert!(!step.is_fallback);
    assert_eq!(
        plan.metadata.permissions.primary,
        [Permission::Accessibility, Permission::Automation].into()
    );
    assert!(plan.metadata.permissions.fallback.is_empty());
}

#[test]
fn windows_shell_actions_select_native_toggle_or_documented_shortcuts() {
    let show_desktop = Plan::for_action(
        &ActionRequest::new(ActionKind::ShowDesktop, None).unwrap(),
        Platform::Windows,
    );
    assert_eq!(show_desktop.steps.len(), 1);
    assert_eq!(show_desktop.steps[0].method, Method::ToggleDesktop {});
    assert!(show_desktop.metadata.is_executable);
    assert!(show_desktop.metadata.permissions.primary.is_empty());
    for (kind, key_code, modifiers) in [
        (ActionKind::ShowWindowOverview, 0x09, 1),
        (ActionKind::ShowNotificationCenter, 0x4e, 1),
        (ActionKind::SwitchToNextVirtualDesktop, 0x27, 9),
        (ActionKind::SwitchToPreviousVirtualDesktop, 0x25, 9),
        (ActionKind::CaptureScreenFull, 0x2c, 1),
        (ActionKind::CaptureScreenSelection, 0x53, 3),
    ] {
        let action = ActionRequest::new(kind, None).unwrap();
        let plan = Plan::for_action(&action, Platform::Windows);
        assert_eq!(plan.steps.len(), 1);
        assert_eq!(
            plan.steps[0].method,
            Method::KeyEvent {
                key_code,
                modifiers
            }
        );
        assert!(plan.metadata.is_executable);
        assert!(plan.metadata.permissions.primary.is_empty());
    }
}

#[test]
fn catalog_exposes_known_platform_support() {
    use ActionKind::*;

    for kind in [
        ShowWindowOverview,
        SelectAll,
        FindInApp,
        ShowDesktop,
        CloseForegroundWindow,
    ] {
        assert_eq!(
            kind.supported_platforms(),
            [Platform::Macos, Platform::Windows],
            "{kind:?}"
        );
    }
    for kind in [
        SleepSystem,
        QuitFrontmostApplication,
        ToggleFocusedWindowFullScreen,
        MissionControlAppExpose,
        RunShortcut,
    ] {
        assert_eq!(kind.supported_platforms(), [Platform::Macos], "{kind:?}");
    }
}

#[test]
fn workspace_validation_is_shared_without_rewriting_saved_input() {
    for platform in [Platform::Macos, Platform::Windows] {
        for (kind, value) in [
            (ActionKind::OpenURL, "https://"),
            (ActionKind::OpenURL, "relative/path"),
            (ActionKind::OpenURL, "https:example"),
            (ActionKind::OpenURL, "https:///example.com"),
            (ActionKind::OpenURL, "https://example.com\\evil"),
            (ActionKind::OpenURL, "https://example.com\0hidden"),
            (ActionKind::OpenFolder, "\0"),
        ] {
            let action = text_action_from_wire(kind, value);
            let plan = serde_json::to_value(Plan::for_action(&action, platform)).unwrap();
            assert_eq!(plan["steps"][0]["method"]["kind"], "invalid-input");
            assert_eq!(plan["isExecutable"], false);
            assert_eq!(action.input(), Some(&ActionInput::String(value.into())));
        }
    }
}

#[test]
fn workspace_wire_plans_keep_saved_values_and_project_executable_inputs() {
    for platform in [Platform::Macos, Platform::Windows] {
        for (kind, input, method, expected) in [
            (
                ActionKind::OpenURL,
                "  https://example.com  ",
                "open-url",
                "https://example.com/",
            ),
            (
                ActionKind::OpenURL,
                "https://example.com/a?x=1&y=2",
                "open-url",
                "https://example.com/a?x=1&y=2",
            ),
            (
                ActionKind::OpenURL,
                "mailto:hello@example.com",
                "open-url",
                "mailto:hello@example.com",
            ),
            (
                ActionKind::OpenURL,
                "custom:日本",
                "open-url",
                "custom:%E6%97%A5%E6%9C%AC",
            ),
            (
                ActionKind::OpenFolder,
                "  /Applications  ",
                "open-folder",
                "/Applications",
            ),
            (
                ActionKind::LaunchApplication,
                "  com.example.App  ",
                "launch-application",
                "com.example.App",
            ),
            (
                ActionKind::RunShortcut,
                "  Daily  ",
                "run-shortcut",
                "Daily",
            ),
        ] {
            let action = text_action_from_wire(kind, input);
            let plan = serde_json::to_value(Plan::for_action(&action, platform)).unwrap();
            let supported = kind != ActionKind::RunShortcut || platform == Platform::Macos;
            let steps = if supported {
                serde_json::json!([{
                    "method": { "kind": method, "value": expected },
                    "isFallback": false,
                }])
            } else {
                serde_json::json!([])
            };
            assert_eq!(plan["steps"], steps, "{kind:?} on {platform:?}");
            assert_eq!(plan["isExecutable"], supported);
            assert_eq!(
                plan["permissions"],
                serde_json::json!({ "primary": [], "fallback": [] })
            );
            assert_eq!(
                action.input(),
                Some(&ActionInput::String(input.trim().into()))
            );
        }
    }
}

fn text_action_from_wire(kind: ActionKind, input: &str) -> ActionRequest {
    let data = serde_json::to_vec(&serde_json::json!({
        "kind": kind.descriptor().identifier,
        "input": input,
    }))
    .unwrap();
    ActionRequest::decode(&data).unwrap()
}

#[test]
fn workspace_plans_normalize_once_and_preserve_non_whitespace_unicode() {
    use desktop_actions::Step;
    for platform in [Platform::Macos, Platform::Windows] {
        for method in [
            Method::OpenFolder {
                value: " \tExample\u{200b}\n ".into(),
            },
            Method::LaunchApplication {
                value: " \t\u{200b}Example\n ".into(),
            },
            Method::RunShortcut {
                value: " \t\u{200b}Example\n ".into(),
            },
        ] {
            let plan = Plan::from_steps(
                vec![Step {
                    method,
                    is_fallback: false,
                }],
                platform,
            );
            let value = match &plan.steps[0].method {
                Method::OpenFolder { value } => {
                    assert_eq!(value, "Example\u{200b}");
                    value
                }
                Method::LaunchApplication { value } | Method::RunShortcut { value } => {
                    assert_eq!(value, "\u{200b}Example");
                    value
                }
                other => panic!("Expected a normalized workspace method, got {other:?}"),
            };
            assert!(
                !value.starts_with(char::is_whitespace) && !value.ends_with(char::is_whitespace)
            );
            assert_eq!(Plan::from_steps(plan.steps.clone(), platform), plan);
        }
    }
}

#[test]
fn workspace_wire_plans_keep_distinct_utf8_path_spellings() {
    for platform in [Platform::Macos, Platform::Windows] {
        for (kind, method, spellings) in [
            (
                ActionKind::OpenFolder,
                "open-folder",
                [
                    ("/tmp/caf\u{e9}", "/tmp/caf\u{e9}"),
                    ("/tmp/cafe\u{301}", "/tmp/cafe\u{301}"),
                ],
            ),
            (
                ActionKind::OpenURL,
                "open-url",
                [
                    (
                        "https://example.invalid/caf\u{e9}",
                        "https://example.invalid/caf%C3%A9",
                    ),
                    (
                        "https://example.invalid/cafe\u{301}",
                        "https://example.invalid/cafe%CC%81",
                    ),
                ],
            ),
        ] {
            let [first, second] = spellings.map(|(input, expected)| {
                let action = text_action_from_wire(kind, input);
                let saved: serde_json::Value = serde_json::from_slice(&action.encode()).unwrap();
                assert_eq!(saved["input"], input);
                let plan = Plan::for_action(&action, platform);
                let wire = serde_json::to_value(&plan).unwrap();
                assert_eq!(
                    wire["steps"][0]["method"],
                    serde_json::json!({ "kind": method, "value": expected }),
                    "{kind:?} on {platform:?}"
                );
                plan
            });
            assert_ne!(first, second);
        }
    }
}

#[test]
fn window_placement_plan_wire_preserves_grid_centered_and_display_options() {
    use serde_json::json;

    for placement in [
        json!({"kind": "fill"}),
        json!({"kind": "grid", "columns": 2, "rows": 1, "column": 0, "row": 0, "columnSpan": 1, "rowSpan": 1}),
        json!({"kind": "grid", "columns": 2, "rows": 1, "column": 1, "row": 0, "columnSpan": 1, "rowSpan": 1}),
        json!({"kind": "grid", "columns": 1, "rows": 2, "column": 0, "row": 1, "columnSpan": 1, "rowSpan": 1}),
        json!({"kind": "grid", "columns": 1, "rows": 2, "column": 0, "row": 0, "columnSpan": 1, "rowSpan": 1}),
        json!({"kind": "centered", "widthRatio": 0.85, "heightRatio": 0.85}),
    ] {
        let request = json!({
            "placement": placement,
            "screen": {"kind": "containing-window"},
            "area": "visible",
            "inset": 0.0,
        });
        assert_window_plan_wire("placement", json!({"placement": placement}), &request);
    }

    for screen in [
        json!({"kind": "ordered-index", "orderedIndex": 1}),
        json!({"kind": "display-identifier", "displayIdentifier": u64::MAX}),
        json!({"kind": "display-identifier", "displayIdentifier": u64::MAX - 1}),
    ] {
        let request = json!({
            "placement": {
                "kind": "grid", "columns": 2, "rows": 2,
                "column": 1, "row": 0, "columnSpan": 1, "rowSpan": 2,
            },
            "screen": screen,
            "area": "full",
            "inset": 8.0,
        });
        assert_window_plan_wire("placement", request.clone(), &request);
    }
}

#[test]
fn window_movement_plan_wire_preserves_direction_and_position_policy() {
    use serde_json::json;

    for direction in ["next", "previous"] {
        assert_window_plan_wire(
            "move",
            json!({"direction": direction}),
            &json!({"direction": direction, "preservesRelativePosition": true}),
        );
        let explicit = json!({"direction": direction, "preservesRelativePosition": false});
        assert_window_plan_wire("move", explicit.clone(), &explicit);
    }
}

fn assert_window_plan_wire(kind: &str, input: serde_json::Value, request: &serde_json::Value) {
    use serde_json::json;

    let action = ActionRequest::decode(
        &serde_json::to_vec(&json!({"kind": format!("action.window.{kind}"), "input": input}))
            .unwrap(),
    )
    .unwrap();

    for (platform, name, permissions, hints) in [
        (
            Platform::Macos,
            "macos",
            json!(["accessibility"]),
            json!([{"permission": "accessibility", "reason": "accessibility-windowing"}]),
        ),
        (Platform::Windows, "windows", json!([]), json!([])),
    ] {
        let plan = serde_json::to_value(Plan::for_action(&action, platform)).unwrap();
        assert_eq!(
            plan,
            json!({
                "platform": name,
                "steps": [{
                    "method": {"kind": format!("window-{kind}"), "request": request},
                    "isFallback": false,
                }],
                "isExecutable": true,
                "permissions": {"primary": permissions, "fallback": []},
                "hints": hints,
            }),
            "{kind} {input} on {platform:?}",
        );
    }
}

#[test]
fn windows_session_lock_is_native_and_keeps_destructive_retry_metadata() {
    let action = ActionRequest::new(ActionKind::LockScreen, None).unwrap();
    let plan = Plan::for_action(&action, Platform::Windows);
    assert_eq!(plan.steps.len(), 1);
    assert_eq!(plan.steps[0].method, Method::LockSession {});
    assert!(!plan.steps[0].is_fallback);
    assert!(plan.metadata.is_executable);
    assert!(action.kind().descriptor().capabilities.is_destructive);
}

#[test]
fn focused_minimization_is_shared_and_never_suggests_a_focus_changing_retry() {
    let action = ActionRequest::new(ActionKind::MinimizeFocusedWindow, None).unwrap();
    for platform in [Platform::Macos, Platform::Windows] {
        let plan = Plan::for_action(&action, platform);
        assert_eq!(plan.steps.len(), 1);
        assert_eq!(plan.steps[0].method, Method::WindowMinimize {});
        assert_eq!(
            plan.metadata
                .permissions
                .primary
                .contains(&Permission::Accessibility),
            platform == Platform::Macos
        );
    }
    let descriptor = action.kind().descriptor();
    assert!(descriptor.capabilities.requires_focused_window);
    assert_eq!(
        descriptor.capabilities.retry_behavior,
        desktop_actions::RetryBehavior::Unsafe
    );
}

#[test]
fn full_screen_toggle_uses_only_native_windowing_on_macos() {
    let saved: &[u8] = br#"{"kind":"action.window.toggle-full-screen"}"#;
    let action = ActionRequest::decode(saved).unwrap();
    assert_eq!(action.kind(), ActionKind::ToggleFocusedWindowFullScreen);
    assert_eq!(action.encode().as_slice(), saved);
    let descriptor = action.kind().descriptor();
    assert_eq!(descriptor.category, "window");
    assert!(descriptor.capabilities.requires_focused_window);
    assert!(!descriptor.capabilities.is_destructive);
    assert_eq!(
        descriptor.capabilities.retry_behavior,
        RetryBehavior::Unsafe
    );

    let mac = Plan::for_action(&action, Platform::Macos);
    let [step] = mac.steps.as_slice() else {
        panic!("Full screen must use a single native window operation");
    };
    assert_eq!(step.method, Method::WindowToggleFullScreen {});
    assert_eq!(
        serde_json::to_value(&step.method).unwrap(),
        serde_json::json!({"kind": "window-toggle-full-screen"})
    );
    assert!(!step.is_fallback);
    assert!(mac.metadata.is_executable);
    assert_eq!(
        mac.metadata.permissions.primary,
        [Permission::Accessibility].into()
    );
    assert!(mac.metadata.permissions.fallback.is_empty());
    assert_eq!(
        mac.metadata.hints,
        [PermissionHint {
            permission: Permission::Accessibility,
            reason: PermissionReason::AccessibilityWindowing,
        }]
    );

    let windows = Plan::for_action(&action, Platform::Windows);
    assert!(windows.steps.is_empty());
    assert!(!windows.metadata.is_executable);
    assert_eq!(action.kind().supported_platforms(), [Platform::Macos]);
}

#[test]
fn application_quit_and_single_window_close_have_distinct_plans_and_capabilities() {
    let quit = ActionRequest::new(ActionKind::QuitFrontmostApplication, None).unwrap();
    let quit_mac = Plan::for_action(&quit, Platform::Macos);
    assert_eq!(quit_mac.steps.len(), 1);
    assert_eq!(
        quit_mac.steps[0].method,
        Method::TerminateFrontmostApplication {}
    );
    assert!(Plan::for_action(&quit, Platform::Windows).steps.is_empty());
    assert_eq!(quit.kind().supported_platforms(), [Platform::Macos]);
    let close = ActionRequest::decode(br#"{"kind":"action.window.close"}"#).unwrap();
    assert_eq!(close.kind(), ActionKind::CloseForegroundWindow);
    assert_eq!(
        ActionRequest::decode_envelope(&close.encode_envelope()).unwrap(),
        close
    );
    for platform in [Platform::Macos, Platform::Windows] {
        let plan = Plan::for_action(&close, platform);
        assert!(plan.metadata.is_executable);
        assert_eq!(plan.steps.len(), 1);
        assert_eq!(plan.steps[0].method, Method::WindowClose {});
        assert!(!plan.steps[0].is_fallback);
        assert_eq!(
            plan.metadata
                .permissions
                .primary
                .contains(&Permission::Accessibility),
            platform == Platform::Macos
        );
        assert!(plan.metadata.permissions.fallback.is_empty());
        assert_eq!(
            serde_json::to_value(&plan.steps[0].method).unwrap(),
            serde_json::json!({"kind":"window-close"})
        );
        if platform == Platform::Macos {
            assert_eq!(
                plan.metadata.hints[0].reason,
                PermissionReason::AccessibilityWindowing
            );
        }
    }
    let capabilities = close.kind().descriptor().capabilities;
    assert!(capabilities.is_destructive);
    assert!(capabilities.requires_focused_window);
    assert!(!capabilities.requires_frontmost_application);
    assert_eq!(
        capabilities.retry_behavior,
        desktop_actions::RetryBehavior::Unsafe
    );
    assert_eq!(
        ActionKind::MissionControlAppExpose.supported_platforms(),
        [Platform::Macos]
    );
}
