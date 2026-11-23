use desktop_actions::*;
use serde_json::json;
use std::collections::HashSet;
use window_management::{DisplayTarget, Placement};

#[test]
fn saved_v1_requests_require_explicit_host_renames_and_current_examples_round_trip() {
    // Captured from the previously accepted public codec, without executing any action.
    let saved: Vec<serde_json::Value> =
        serde_json::from_str(include_str!("fixtures/saved-actions-v1.json")).unwrap();
    // JSON 0 and 0.0 carry the same value. Preserve exact legacy integers;
    // only canonicalize integral floats that fit an exact integer representation.
    fn integral_numbers(value: &mut serde_json::Value) {
        match value {
            serde_json::Value::Array(values) => values.iter_mut().for_each(integral_numbers),
            serde_json::Value::Object(values) => values.values_mut().for_each(integral_numbers),
            serde_json::Value::Number(number) if number.is_f64() => {
                let value = number.as_f64().unwrap();
                if value.fract() == 0.0 {
                    let text = format!("{value:.0}");
                    if let Ok(integer) = text.parse::<i64>() {
                        *number = integer.into();
                    } else if let Ok(integer) = text.parse::<u64>() {
                        *number = integer.into();
                    }
                }
            }
            _ => {}
        }
    }
    assert!(!saved.is_empty());
    for old in &saved {
        let mut expected = old.clone();
        let identifier = old["action"]["kind"].as_str().unwrap();
        let replacement = match identifier {
            "action.system.mission-control" => Some("action.system.show-window-overview"),
            "action.system.mission-control-next-space" => {
                Some("action.system.switch-to-next-virtual-desktop")
            }
            "action.system.mission-control-previous-space" => {
                Some("action.system.switch-to-previous-virtual-desktop")
            }
            _ => None,
        };
        if let Some(replacement) = replacement {
            assert_eq!(
                ActionRequest::decode_envelope(&serde_json::to_vec(old).unwrap())
                    .unwrap_err()
                    .code,
                CodecErrorCode::UnknownAction
            );
            // Illustrate the required host data migration; no public codec alias is retained.
            expected["action"]["kind"] = replacement.into();
        }
        let action =
            ActionRequest::decode_envelope(&serde_json::to_vec(&expected).unwrap()).unwrap();
        let mut encoded: serde_json::Value =
            serde_json::from_slice(&action.encode_envelope()).unwrap();
        integral_numbers(&mut encoded);
        integral_numbers(&mut expected);
        assert_eq!(encoded, expected, "Saved v1 data changed meaning or fields");
    }
    // Current examples evolve independently of the captured historical requests.
    let mut identifiers = HashSet::new();
    let mut kinds = HashSet::new();
    for descriptor in catalog() {
        assert!(identifiers.insert(&descriptor.identifier));
        assert!(kinds.insert(descriptor.name));
        let action = ActionRequest::new(
            descriptor.name,
            descriptor
                .input_descriptor
                .parameter
                .as_ref()
                .map(|v| v.example_input.clone()),
        )
        .unwrap();
        assert_eq!(
            action,
            ActionRequest::decode_envelope(&action.encode_envelope()).unwrap()
        );
        assert_eq!(action, ActionRequest::decode(&action.encode()).unwrap());
    }
}

#[test]
fn every_kind_rejects_missing_or_mismatched_input_in_construction_and_decoding() {
    let inputs = [
        None,
        Some(ActionInput::String("value".into())),
        Some(ActionInput::WindowPlacement(
            serde_json::from_value(json!({
                "placement": {
                    "kind": "grid", "columns": 2, "rows": 1,
                    "column": 0, "row": 0, "columnSpan": 1, "rowSpan": 1
                }
            }))
            .unwrap(),
        )),
        Some(ActionInput::WindowMove(
            serde_json::from_value(json!({"direction": "next"})).unwrap(),
        )),
    ];
    for descriptor in catalog() {
        for input in &inputs {
            let shape = input.as_ref().map_or(InputShape::None, ActionInput::shape);
            if shape == descriptor.input_descriptor.shape {
                continue;
            }
            let action = descriptor.name;
            let constructed = ActionRequest::new(action, input.clone()).unwrap_err();
            assert_eq!(
                constructed.code,
                CodecErrorCode::InvalidData,
                "{action:?} {shape:?}"
            );
            let mut wire = json!({"kind": descriptor.identifier});
            if let Some(input) = input {
                wire["input"] = serde_json::to_value(input).unwrap()["value"].clone();
            }
            let decoded = ActionRequest::decode(&serde_json::to_vec(&wire).unwrap()).unwrap_err();
            assert_eq!(decoded.code, CodecErrorCode::InvalidData, "{wire}");
        }
    }
}

#[test]
fn every_text_kind_rejects_blank_input_and_trims_outer_whitespace() {
    for descriptor in catalog() {
        let Some(ActionInput::String(example)) = descriptor
            .input_descriptor
            .parameter
            .as_ref()
            .map(|parameter| &parameter.example_input)
        else {
            continue;
        };
        let action = descriptor.name;
        for value in ["", " \n\t ", "\u{2003}"] {
            let error =
                ActionRequest::new(action, Some(ActionInput::String(value.into()))).unwrap_err();
            assert_eq!(
                error.code,
                CodecErrorCode::InvalidData,
                "{action:?} {value:?}"
            );
            let wire = json!({"kind": descriptor.identifier, "input": value});
            let error = ActionRequest::decode(&serde_json::to_vec(&wire).unwrap()).unwrap_err();
            assert_eq!(error.code, CodecErrorCode::InvalidData, "{wire}");
        }
        let padded = format!(" \u{2003}{example}\n");
        let expected = ActionInput::String(example.clone());
        let constructed =
            ActionRequest::new(action, Some(ActionInput::String(padded.clone()))).unwrap();
        let wire = json!({"kind": descriptor.identifier, "input": padded});
        let decoded = ActionRequest::decode(&serde_json::to_vec(&wire).unwrap()).unwrap();
        assert_eq!(constructed.input(), Some(&expected), "{action:?}");
        assert_eq!(decoded, constructed, "{wire}");
    }
}

#[test]
fn strict_action_boundaries_reject_typos_nulls_mismatched_shapes_and_duplicate_keys() {
    for bad in [
        r#"{"kind":"action.editing.copy","input":null}"#,
        r#"{"kind":"action.editing.copy","input":"text"}"#,
        r#"{"kind":"action.editing.copy","unknown":true}"#,
        r#"{"kind":"action.editing.copy","kind":"action.editing.paste"}"#,
        r#"{"kind":"action.workspace.open-url"}"#,
        r#"{"kind":"action.workspace.open-url","input":null}"#,
        r#"{"kind":"action.workspace.open-url","input":" \n\t "}"#,
        r#"{"kind":"action.window.placement","input":{"placement":{"kind":"fill","columns":2}}}"#,
        r#"{"kind":"action.window.placement","input":{"placement":{"kind":"fill"},"area":null}}"#,
        r#"{"kind":"action.window.placement","input":{"placement":{"kind":"fill"},"screen":null}}"#,
        r#"{"kind":"action.window.placement","input":{"placement":{"kind":"fill"},"inset":null}}"#,
        r#"{"kind":"action.window.placement","input":{"placement":{"kind":"centered","widthRatio":0.4,"widthRatio":0.5,"heightRatio":1}}}"#,
        r#"{"kind":"action.window.move","input":{"direction":"next","preservesRelativePosition":null}}"#,
        r#"{"kind":"action.window.move","input":{"direction":"next","extra":true}}"#,
    ] {
        assert!(ActionRequest::decode(bad.as_bytes()).is_err(), "{bad}");
    }
    let unknown = ActionRequest::decode(br#"{"kind":"action.future.new"}"#).unwrap_err();
    assert_eq!(unknown.code, CodecErrorCode::UnknownAction);
    assert_eq!(
        ActionRequest::decode_envelope(br#"{"version":999}"#)
            .unwrap_err()
            .version,
        Some(999)
    );
    assert_eq!(
        ActionRequest::decode_envelope(br#"{"version":2,"action":{"kind":"new-kind"}}"#)
            .unwrap_err()
            .version,
        Some(2)
    );
    for bad in [
        r#"{"version":1,"version":2,"action":{"kind":"action.editing.copy"}}"#,
        r#"{"version":1,"extra":true,"action":{"kind":"action.editing.copy"}}"#,
        r#"{"version":1.0,"action":{"kind":"action.editing.copy"}}"#,
    ] {
        assert!(
            ActionRequest::decode_envelope(bad.as_bytes()).is_err(),
            "{bad}"
        );
    }
}
#[test]
fn native_values_normalize_strings_and_shared_window_requests_once() {
    let a = ActionRequest::decode(
        br#"{"kind":"action.workspace.open-url","input":"  https://example.com  "}"#,
    )
    .unwrap();
    assert_eq!(
        a.input(),
        Some(&ActionInput::String("https://example.com".into()))
    );
    let a = ActionRequest::decode(br#"{"kind":"action.window.placement","input":{"placement":{"kind":"grid","columns":0,"rows":2,"column":-10,"row":99,"columnSpan":99,"rowSpan":0},"screen":{"kind":"ordered-index","orderedIndex":-3},"inset":-10}}"#).unwrap();
    let Some(ActionInput::WindowPlacement(request)) = a.input() else {
        panic!("placement");
    };
    assert_eq!(
        request.placement,
        Placement::Grid {
            columns: 1,
            rows: 2,
            column: 0,
            row: 1,
            column_span: 1,
            row_span: 1
        }
    );
    assert_eq!(
        request.display,
        DisplayTarget::OrderedIndex { ordered_index: 0 }
    );
    assert_eq!(request.inset, 0.0);
    let a =
        ActionRequest::decode(br#"{"kind":"action.window.move","input":{"direction":"previous"}}"#)
            .unwrap();
    let Some(ActionInput::WindowMove(request)) = a.input() else {
        panic!("move");
    };
    assert!(request.preserves_relative_position);
}

#[test]
fn window_request_equality_equates_signed_zero_and_distinguishes_exact_display_ids() {
    let point = |x: &str| {
        ActionRequest::decode(
            format!(
                r#"{{"kind":"action.window.placement","input":{{"placement":{{"kind":"fill"}},"screen":{{"kind":"point","x":{x},"y":2.0}}}}}}"#
            )
            .as_bytes(),
        )
        .unwrap()
    };
    assert_eq!(point("0.0"), point("-0.0"));
    assert_ne!(point("0.0").encode(), point("-0.0").encode());

    let display = |id: u64| {
        ActionRequest::decode(
            format!(
                r#"{{"kind":"action.window.placement","input":{{"placement":{{"kind":"fill"}},"screen":{{"kind":"display-identifier","displayIdentifier":{id}}}}}}}"#
            )
            .as_bytes(),
        )
        .unwrap()
    };
    assert_ne!(display(u64::MAX), display(u64::MAX - 1));
}

#[test]
fn hyphenated_keys_and_platform_mapping_remain_physical() {
    for input in ["ctrl-page-down", "ctrl+page-down", "ctrl page-down"] {
        assert_eq!(
            parse_shortcut(input),
            Some(KeyStroke {
                usage: 0x4e,
                modifiers: 8
            })
        );
    }
    for input in ["ctrl--page-down", "⌘--x", "cmd-", "shift+shift+1"] {
        assert!(parse_shortcut(input).is_none(), "{input}");
    }
    let cmd_c = parse_shortcut("⌘C").unwrap();
    assert_eq!(cmd_c.usage, 6);
    assert_eq!(macos_key_code(cmd_c.usage), Some(8));
    assert!(parse_shortcut("ctrl+f24").is_some());
    assert_eq!(macos_key_code(0x73), None);
}

#[test]
fn bare_return_symbol_matches_text_presentation_and_named_return() {
    let expected = Some(KeyStroke {
        usage: 0x28,
        modifiers: ModifierFlags::META,
    });
    assert_eq!(
        parse_shortcut("⌘\u{21a9}"),
        expected,
        "The bare U+21A9 Return symbol must parse as Command-Return"
    );
    assert_eq!(parse_shortcut("⌘\u{21a9}\u{fe0e}"), expected);
    assert_eq!(parse_shortcut("cmd+return"), expected);
    assert_eq!(macos_key_code(0x28), Some(0x24));
    assert!(parse_shortcut("⌘\u{21a9}\u{fe0f}").is_none());
    assert!(parse_shortcut("⌘⌘\u{21a9}").is_none());
}
