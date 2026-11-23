use std::collections::BTreeSet;

use desktop_actions::{
    ActionInput, ActionKind, ActionRequest, ENVELOPE_VERSION, Method, Permission, PermissionHint,
    PermissionReason, Plan, Platform, Step,
};
use window_management::{DisplayArea, DisplayTarget, Placement, PlacementRequest};

fn main() {
    let request = PlacementRequest {
        placement: Placement::Fill {},
        display: DisplayTarget::Main {},
        area: DisplayArea::Visible,
        inset: 12.5,
    };
    let action = ActionRequest::new(
        ActionKind::WindowPlacement,
        Some(ActionInput::WindowPlacement(request)),
    )
    .expect("the WindowManagement placement request is valid");

    assert_eq!(ENVELOPE_VERSION, 1);
    let saved = br#"{
        "version": 1,
        "action": {
            "kind": "action.window.placement",
            "input": {
                "placement": {"kind": "fill"},
                "screen": {"kind": "main"},
                "area": "visible",
                "inset": 12.5
            }
        }
    }"#;
    assert_eq!(
        ActionRequest::decode_envelope(saved).expect("decode a saved v1 placement"),
        action
    );
    let restored = ActionRequest::decode_envelope(&action.encode_envelope())
        .expect("roundtrip the v1 placement");
    assert_eq!(restored, action);

    let step = Step {
        method: Method::WindowPlacement { request },
        is_fallback: false,
    };
    let macos = Plan::for_action(&restored, Platform::Macos);
    assert_eq!(macos.steps.as_slice(), std::slice::from_ref(&step));
    assert!(macos.metadata.is_executable);
    assert_eq!(
        macos.metadata.permissions.primary,
        BTreeSet::from([Permission::Accessibility])
    );
    assert!(macos.metadata.permissions.fallback.is_empty());
    assert_eq!(
        macos.metadata.hints,
        [PermissionHint {
            permission: Permission::Accessibility,
            reason: PermissionReason::AccessibilityWindowing,
        }]
    );

    let windows = Plan::for_action(&restored, Platform::Windows);
    assert_eq!(windows.steps.as_slice(), std::slice::from_ref(&step));
    assert!(windows.metadata.is_executable);
    assert!(windows.metadata.permissions.primary.is_empty());
    assert!(windows.metadata.permissions.fallback.is_empty());
    assert!(windows.metadata.hints.is_empty());

    println!(
        "Standalone Rust Git DesktopActions consumer passed WindowManagement request roundtrip and platform permission planning."
    );
}
