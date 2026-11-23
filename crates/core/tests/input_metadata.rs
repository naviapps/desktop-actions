use desktop_actions::{
    ActionInput, CodecErrorCode, InputDescriptor, InputParameter, InputShape, catalog,
};

#[test]
fn tagged_inputs_reject_missing_null_malformed_duplicate_and_unknown_fields() {
    for bad in [
        r#"{}"#,
        r#"{"shape":"none","value":null}"#,
        r#"{"shape":"string"}"#,
        r#"{"shape":"string","value":" \t\u0085"}"#,
        r#"{"shape":"string","value":null}"#,
        r#"{"shape":"string","value":{"direction":"next"}}"#,
        r#"{"shape":"string","value":"x","value":"y"}"#,
        r#"{"shape":"string","value":"x","metadata":{}}"#,
        r#"{"shape":"window-placement","value":{"placement":{"kind":"fill","columns":2}}}"#,
        r#"{"shape":"window-placement","value":{"placement":{"kind":"fill"},"screen":null}}"#,
        r#"{"shape":"window-move","value":{"direction":"next","direction":"previous"}}"#,
        r#"{"shape":"window-move","value":{"direction":"next","preservesRelativePosition":null}}"#,
    ] {
        assert_eq!(
            ActionInput::decode(bad.as_bytes()).unwrap_err().code,
            CodecErrorCode::InvalidData,
            "{bad}"
        );
    }
}

#[test]
fn tagged_inputs_normalize_text_and_window_values_without_losing_identity() {
    for (source, canonical) in [
        (
            r#"{"shape":"string","value":" \t\u200bExample\u200b\n "}"#,
            "{\"shape\":\"string\",\"value\":\"\u{200b}Example\u{200b}\"}",
        ),
        (
            r#"{"shape":"window-placement","value":{"placement":{"kind":"fill"},"screen":{"kind":"display-identifier","displayIdentifier":18446744073709551615},"inset":-1}}"#,
            r#"{"shape":"window-placement","value":{"placement":{"kind":"fill"},"screen":{"kind":"display-identifier","displayIdentifier":18446744073709551615},"area":"visible","inset":0.0}}"#,
        ),
        (
            r#"{"shape":"window-move","value":{"direction":"previous","preservesRelativePosition":false}}"#,
            r#"{"shape":"window-move","value":{"direction":"previous","preservesRelativePosition":false}}"#,
        ),
    ] {
        let value = ActionInput::decode(source.as_bytes()).unwrap();
        assert_eq!(serde_json::to_string(&value).unwrap(), canonical);
        assert_eq!(ActionInput::decode(canonical.as_bytes()).unwrap(), value);
    }
    assert_ne!(
        ActionInput::decode(br#"{"shape":"string","value":"\u00e9"}"#).unwrap(),
        ActionInput::decode(br#"{"shape":"string","value":"e\u0301"}"#).unwrap()
    );
}

#[test]
fn parameter_metadata_normalizes_labels_with_the_existing_swift_whitespace_contract() {
    let parameter = InputParameter::decode(
        br#"{"name":" \u200burl\u200b ","description":"\u0085URL string.\t","exampleInput":{"shape":"string","value":" \u200bapp\u200b "}}"#,
    )
    .unwrap();
    assert_eq!(parameter.name, "url");
    assert_eq!(parameter.description, "URL string.");
    assert_eq!(
        parameter.example_input,
        ActionInput::String("\u{200b}app\u{200b}".into())
    );

    for bad in [
        r#"["url","Description",{"shape":"string","value":"text"}]"#,
        r#"{"name":"\u200b","description":"Description","exampleInput":{"shape":"string","value":"text"}}"#,
        r#"{"name":"url","description":" \t","exampleInput":{"shape":"string","value":"text"}}"#,
        r#"{"name":"url","description":"Description","exampleInput":{"shape":"string","value":" "}}"#,
        r#"{"name":"url","description":"Description","exampleInput":null}"#,
        r#"{"name":"url","name":"other","description":"Description","exampleInput":{"shape":"string","value":"text"}}"#,
        r#"{"name":"url","description":"Description","exampleInput":{"shape":"string","value":"text"},"metadata":{}}"#,
    ] {
        assert_eq!(
            InputParameter::decode(bad.as_bytes()).unwrap_err().code,
            CodecErrorCode::InvalidData,
            "{bad}"
        );
    }
}

#[test]
fn descriptors_require_an_object_parameter_only_for_matching_input_shapes() {
    let none = InputDescriptor::decode(br#"{"shape":"none"}"#).unwrap();
    assert_eq!(none.shape, InputShape::None);
    assert!(none.parameter.is_none());

    let param = r#"{"name":" label ","description":"Description","exampleInput":{"shape":"string","value":" example "}}"#;
    let descriptor =
        InputDescriptor::decode(format!(r#"{{"shape":"string","parameter":{param}}}"#).as_bytes())
            .unwrap();
    assert_eq!(
        descriptor.parameter.unwrap(),
        InputParameter::decode(param.as_bytes()).unwrap()
    );
    for bad in [
        format!(r#"{{"shape":"none","parameter":{param}}}"#),
        format!(r#"{{"shape":"window-placement","parameter":{param}}}"#),
        format!(r#"{{"shape":"window-move","parameter":{param}}}"#),
        format!(r#"{{"shape":"string","parameter":{param},"parameter":{param}}}"#),
        r#"["none"]"#.into(),
        r#"{"shape":"none","parameter":null}"#.into(),
        r#"{"shape":"string","parameter":null}"#.into(),
        r#"{"shape":"string"}"#.into(),
        r#"{"shape":"string","parameter":["label","Description",{"shape":"string","value":"text"}]}"#.into(),
        r#"{"shape":"none","metadata":{}}"#.into(),
    ] {
        assert_eq!(
            InputDescriptor::decode(bad.as_bytes()).unwrap_err().code,
            CodecErrorCode::InvalidData,
            "{bad}"
        );
    }
}

#[test]
fn catalog_input_descriptors_round_trip_through_the_shared_metadata_codec() {
    for entry in catalog() {
        let descriptor = &entry.input_descriptor;
        let wire = serde_json::to_vec(descriptor).unwrap();
        assert_eq!(&InputDescriptor::decode(&wire).unwrap(), descriptor);
    }
}
