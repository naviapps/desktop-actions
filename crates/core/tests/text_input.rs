use desktop_actions::*;

fn evaluate(kind: ActionKind, value: &str, shortcuts: Option<Vec<&str>>) -> TextInputEvaluation {
    TextInputRequest {
        identifier: kind.descriptor().identifier.clone(),
        value: value.into(),
        platform: Platform::Macos,
        shortcuts: shortcuts.map(|names| names.into_iter().map(String::from).collect()),
        directory_exists: None,
    }
    .evaluate()
    .unwrap()
}

#[test]
fn draft_wire_preserves_proposals_and_observation_boundaries() {
    for row in include_str!("fixtures/draft-evaluations.tsv").lines() {
        let (name, fields) = row.split_once('\t').unwrap();
        let (request, expected) = fields.split_once('\t').unwrap();
        let response = serde_json::from_str::<TextInputRequest>(request)
            .ok()
            .and_then(TextInputRequest::evaluate)
            .map(|result| serde_json::to_string(&result).unwrap());
        assert_eq!(
            response.as_deref(),
            (expected != "-").then_some(expected),
            "{name}"
        );
    }
}

#[test]
fn catalog_forms_match_shapes_and_never_depend_on_language_name_spelling() {
    for entry in catalog() {
        let expected = match entry.input_form {
            InputForm::None => InputShape::None,
            InputForm::WindowPlacement => InputShape::WindowPlacement,
            InputForm::WindowMove => InputShape::WindowMove,
            _ => InputShape::String,
        };
        assert_eq!(entry.input_descriptor.shape, expected);
    }
    assert_eq!(ActionKind::OpenURL.descriptor().input_form, InputForm::Url);
    assert_eq!(
        ActionKind::RunShortcut.descriptor().input_form,
        InputForm::Shortcut
    );
}

#[test]
fn input_validation_shares_executable_plans_without_changing_the_draft() {
    assert_eq!(
        evaluate(ActionKind::OpenURL, "https:example", None).issue,
        Some(TextInputIssue::InvalidUrl)
    );
    assert_eq!(
        evaluate(ActionKind::KeyboardShortcut, "cmd", None).issue,
        Some(TextInputIssue::InvalidKeyboardShortcut)
    );
    let evaluation = evaluate(ActionKind::OpenURL, "  https://example.com  ", None);
    assert!(evaluation.can_confirm);
    assert_eq!(evaluation.confirmed_value, "https://example.com");
    let empty = evaluate(ActionKind::OpenURL, " \u{2003}\n", None);
    assert!(!empty.can_confirm);
    assert_eq!(empty.issue, None);
    assert_eq!(
        evaluate(ActionKind::OpenFolder, "bad\0value", None).issue,
        Some(TextInputIssue::InvalidInput)
    );
}

#[test]
fn shortcut_selection_is_exact_first_unambiguous_and_order_independent() {
    for names in [vec!["Morning", "morning"], vec!["morning", "Morning"]] {
        for name in &names {
            assert_eq!(
                evaluate(ActionKind::RunShortcut, name, Some(names.clone())).confirmed_value,
                *name
            );
        }
        assert_eq!(
            evaluate(ActionKind::RunShortcut, "MORNING", Some(names)).issue,
            Some(TextInputIssue::AmbiguousShortcut)
        );
    }
    assert_eq!(
        evaluate(
            ActionKind::RunShortcut,
            " MORNING ",
            Some(vec!["Morning", "Morning"])
        )
        .confirmed_value,
        "Morning"
    );
    assert_eq!(
        evaluate(ActionKind::RunShortcut, "Missing", Some(vec!["Morning"])).issue,
        Some(TextInputIssue::ShortcutNotFound)
    );
    for names in [None, Some(vec![])] {
        assert!(evaluate(ActionKind::RunShortcut, " Manual ", names).can_confirm);
    }
}

#[test]
fn format_characters_and_unicode_names_survive_input_evaluation() {
    for kind in [
        ActionKind::RunShortcut,
        ActionKind::OpenFolder,
        ActionKind::LaunchApplication,
    ] {
        let value = "\u{200b}日本語\u{200b}";
        assert_eq!(
            evaluate(kind, &format!("  {value}\n"), None).confirmed_value,
            value
        );
    }
    let evaluation = evaluate(
        ActionKind::RunShortcut,
        "\u{200b}Example",
        Some(vec!["\u{200b}Example", "Example"]),
    );
    assert_eq!(evaluation.confirmed_value, "\u{200b}Example");
}

#[test]
fn keyboard_confirmation_distinguishes_unsupported_platform_from_malformed_input() {
    for (value, platform, expected_issue) in [
        (
            "fn+f11",
            Platform::Windows,
            Some(TextInputIssue::UnsupportedPlatform),
        ),
        ("fn+f11", Platform::Macos, None),
        ("ctrl+f24", Platform::Windows, None),
        (
            "fn++f11",
            Platform::Windows,
            Some(TextInputIssue::InvalidKeyboardShortcut),
        ),
    ] {
        let evaluation = TextInputRequest {
            identifier: ActionKind::KeyboardShortcut.descriptor().identifier.clone(),
            value: value.into(),
            platform,
            shortcuts: None,
            directory_exists: None,
        }
        .evaluate()
        .unwrap();
        assert_eq!(evaluation.issue, expected_issue);
        assert_eq!(evaluation.can_confirm, expected_issue.is_none());
        assert_eq!(evaluation.normalized_value, value);
        assert_eq!(evaluation.confirmed_value, value);
    }
}

#[test]
fn native_observations_are_explicit_and_unsupported_actions_are_not_substituted() {
    let request = |kind: ActionKind, platform, directory_exists| TextInputRequest {
        identifier: kind.descriptor().identifier.clone(),
        value: "/fixture".into(),
        platform,
        shortcuts: None,
        directory_exists,
    };
    assert_eq!(
        request(ActionKind::OpenFolder, Platform::Macos, Some(false))
            .evaluate()
            .unwrap()
            .issue,
        Some(TextInputIssue::DirectoryUnavailable)
    );
    assert!(
        request(ActionKind::OpenFolder, Platform::Macos, Some(true))
            .evaluate()
            .unwrap()
            .can_confirm
    );
    assert_eq!(
        request(ActionKind::RunShortcut, Platform::Windows, None)
            .evaluate()
            .unwrap()
            .issue,
        Some(TextInputIssue::UnsupportedPlatform)
    );
    assert!(
        request(ActionKind::Copy, Platform::Macos, None)
            .evaluate()
            .is_none()
    );
}
