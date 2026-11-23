use desktop_actions::{KeyStroke, ModifierFlags, macos_key_code, parse_shortcut};

fn assert_strokes(cases: &[(&str, u16, u16, u16)]) {
    for &(shortcut, usage, key_code, modifiers) in cases {
        let stroke = parse_shortcut(shortcut);
        assert_eq!(stroke, Some(KeyStroke { usage, modifiers }), "{shortcut:?}");
        assert_eq!(macos_key_code(usage), Some(key_code), "{shortcut:?}");
    }
}

#[test]
fn physical_shortcuts_accept_symbolic_and_named_modifiers() {
    let meta = ModifierFlags::META;
    let shift = ModifierFlags::SHIFT;
    let alt = ModifierFlags::ALT;
    let ctrl = ModifierFlags::CONTROL;

    // Expected USB HID usage and Carbon ANSI virtual key are distinct coordinates.
    assert_strokes(&[
        ("c", 0x06, 0x08, 0),
        ("⌘C", 0x06, 0x08, meta),
        ("⌘+C", 0x06, 0x08, meta),
        ("⌘-C", 0x06, 0x08, meta),
        ("⌘⇧C", 0x06, 0x08, meta | shift),
        ("⌘⇧K", 0x0e, 0x28, meta | shift),
        ("⌃⌥C", 0x06, 0x08, ctrl | alt),
        ("cmd shift z", 0x1d, 0x06, meta | shift),
        ("cmd-shift-z", 0x1d, 0x06, meta | shift),
        ("command option c", 0x06, 0x08, meta | alt),
        ("command+option+c", 0x06, 0x08, meta | alt),
        (" command + option + c ", 0x06, 0x08, meta | alt),
        ("COMMAND+OPTION+C", 0x06, 0x08, meta | alt),
    ]);
}

#[test]
fn punctuation_and_named_symbols_keep_their_physical_positions() {
    let meta = ModifierFlags::META;
    let shifted = meta | ModifierFlags::SHIFT;

    assert_strokes(&[
        ("cmd+-", 0x2d, 0x1b, meta),
        ("cmd+minus", 0x2d, 0x1b, meta),
        ("cmd+plus", 0x2e, 0x18, shifted),
        ("cmd+?", 0x38, 0x2c, shifted),
        ("cmd+_", 0x2d, 0x1b, shifted),
        ("cmd+:", 0x33, 0x29, shifted),
        ("cmd+!", 0x1e, 0x12, shifted),
    ]);
}

#[test]
fn navigation_and_function_keys_accept_the_existing_aliases() {
    let meta = ModifierFlags::META;
    let function = ModifierFlags::FUNCTION;

    assert_strokes(&[
        ("cmd home", 0x4a, 0x73, meta),
        ("cmd-page-down", 0x4e, 0x79, meta),
        ("shift page-down", 0x4e, 0x79, ModifierFlags::SHIFT),
        (
            "ctrl+alt+page-down",
            0x4e,
            0x79,
            ModifierFlags::CONTROL | ModifierFlags::ALT,
        ),
        ("fn forward-delete", 0x4c, 0x75, function),
        ("fn-forward-delete", 0x4c, 0x75, function),
        ("cmd+⌫", 0x2a, 0x33, meta),
        ("cmd+←", 0x50, 0x7b, meta),
        ("fn f11", 0x44, 0x67, function),
        ("function+f11", 0x44, 0x67, function),
        ("cmd f20", 0x6f, 0x5a, meta),
    ]);
    assert_eq!(
        parse_shortcut("f24"),
        Some(KeyStroke {
            usage: 0x73,
            modifiers: 0
        })
    );
    assert_eq!(macos_key_code(0x73), None);
}

#[test]
fn invalid_shortcuts_do_not_fall_back_to_a_partial_stroke() {
    for shortcut in [
        "",
        "cmd",
        "⌘",
        "cmd hyper c",
        "cmd unknown",
        "cmd+unknown",
        "cmd cmd c",
        "cmd+cmd+c",
        "cmd+cmd+k",
        "⌘⌘C",
        "⌘⌘x",
        "⌘cmd+C",
        "cmd++c",
        "ctrl++x",
        "cmd--page-down",
        "cmd-page--down",
        "⌘++C",
        "⌘--C",
    ] {
        assert_eq!(parse_shortcut(shortcut), None, "{shortcut:?}");
    }
}
