use serde::{Deserialize, Serialize};
/// Portable modifier bits. Meta is Command on macOS and the Windows key on Windows;
/// Control remains Control. Function is explicit and may be unsupported by an adapter.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ModifierFlags(pub u16);
impl ModifierFlags {
    pub const META: u16 = 1;
    pub const SHIFT: u16 = 2;
    pub const ALT: u16 = 4;
    pub const CONTROL: u16 = 8;
    pub const FUNCTION: u16 = 16;
}
/// A physical US-ANSI key position using a USB HID keyboard usage, not Unicode text.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct KeyStroke {
    pub usage: u16,
    pub modifiers: u16,
}
fn modifier(value: &str) -> Option<u16> {
    Some(match value {
        "⌘" | "cmd" | "command" | "meta" | "super" | "win" => 1,
        "⇧" | "shift" => 2,
        "⌥" | "opt" | "option" | "alt" => 4,
        "⌃" | "ctrl" | "control" => 8,
        "fn" | "function" => 16,
        _ => return None,
    })
}
fn key(value: &str) -> Option<(u16, u16)> {
    if value.len() == 1 {
        let c = value.as_bytes()[0];
        if c.is_ascii_lowercase() {
            return Some((u16::from(c - b'a') + 4, 0));
        }
        if (b'1'..=b'9').contains(&c) {
            return Some((u16::from(c - b'1') + 0x1e, 0));
        }
    }
    Some(match value {
        "0" => (0x27, 0),
        "return" | "enter" | "\u{21a9}" | "\u{21a9}\u{fe0e}" => (0x28, 0),
        "escape" | "esc" | "⎋" => (0x29, 0),
        "delete" | "backspace" | "⌫" => (0x2a, 0),
        "tab" | "⇥" => (0x2b, 0),
        "space" | "spacebar" => (0x2c, 0),
        "-" | "minus" => (0x2d, 0),
        "_" => (0x2d, 2),
        "=" | "equal" | "equals" => (0x2e, 0),
        "plus" => (0x2e, 2),
        "[" => (0x2f, 0),
        "{" => (0x2f, 2),
        "]" => (0x30, 0),
        "}" => (0x30, 2),
        "\\" => (0x31, 0),
        "|" => (0x31, 2),
        ";" => (0x33, 0),
        ":" => (0x33, 2),
        "'" => (0x34, 0),
        "\"" => (0x34, 2),
        "`" => (0x35, 0),
        "~" => (0x35, 2),
        "," => (0x36, 0),
        "<" => (0x36, 2),
        "." => (0x37, 0),
        ">" => (0x37, 2),
        "/" => (0x38, 0),
        "?" => (0x38, 2),
        "!" => (0x1e, 2),
        "@" => (0x1f, 2),
        "#" => (0x20, 2),
        "$" => (0x21, 2),
        "%" => (0x22, 2),
        "^" => (0x23, 2),
        "&" => (0x24, 2),
        "*" => (0x25, 2),
        "(" => (0x26, 2),
        ")" => (0x27, 2),
        "home" | "↖" => (0x4a, 0),
        "page-up" | "pageup" | "⇞" => (0x4b, 0),
        "forward-delete" | "forwarddelete" | "⌦" => (0x4c, 0),
        "end" | "↘" => (0x4d, 0),
        "page-down" | "pagedown" | "⇟" => (0x4e, 0),
        "right" | "→" => (0x4f, 0),
        "left" | "←" => (0x50, 0),
        "down" | "↓" => (0x51, 0),
        "up" | "↑" => (0x52, 0),
        _ => {
            let f = value.strip_prefix('f')?.parse::<u16>().ok()?;
            if (1..=12).contains(&f) {
                (0x39 + f, 0)
            } else if (13..=24).contains(&f) {
                (0x68 + f - 13, 0)
            } else {
                return None;
            }
        }
    })
}
/// Parse named/symbolic modifiers and a physical key position. Duplicate modifiers,
/// empty components and unknown keys fail. This never types Unicode or queries an OS.
pub fn parse_shortcut(value: &str) -> Option<KeyStroke> {
    let normalized = value.trim().to_lowercase();
    let mut rest = normalized.as_str();
    let mut flags = 0_u16;
    loop {
        let ch = rest.chars().next()?;
        let token = ch.to_string();
        let Some(flag) = modifier(&token) else {
            break;
        };
        if flags & flag != 0 {
            return None;
        }
        flags |= flag;
        rest = &rest[ch.len_utf8()..];
    }
    rest = rest.trim();
    if flags != 0
        && (rest.starts_with('+')
            || (rest.starts_with('-') && rest != "-" && !rest.starts_with("--")))
    {
        rest = rest[1..].trim();
    }
    let tokens: Vec<String> = if rest.contains('+') {
        rest.split('+').map(|v| v.trim().to_owned()).collect()
    } else if rest.chars().any(char::is_whitespace) {
        rest.split_whitespace().map(str::to_owned).collect()
    } else if rest.contains('-') && rest != "-" && key(rest).is_none() {
        let parts: Vec<_> = rest.split('-').map(str::trim).collect();
        if parts.iter().any(|v| v.is_empty()) {
            return None;
        }
        let split = (0..parts.len()).find(|&i| {
            parts[..i].iter().all(|v| modifier(v).is_some()) && key(&parts[i..].join("-")).is_some()
        })?;
        let mut tokens: Vec<_> = parts[..split].iter().map(|v| (*v).to_owned()).collect();
        tokens.push(parts[split..].join("-"));
        tokens
    } else {
        vec![rest.to_owned()]
    };
    let (last, modifiers) = tokens.split_last()?;
    if last.is_empty() {
        return None;
    }
    for token in modifiers {
        let flag = modifier(token)?;
        if flags & flag != 0 {
            return None;
        }
        flags |= flag;
    }
    let (usage, implied) = key(last)?;
    Some(KeyStroke {
        usage,
        modifiers: flags | implied,
    })
}

/// Convert the physical keyboard usage to a macOS ANSI virtual key code. This is a
/// coordinate mapping only; it does not resolve a character in the active keyboard layout.
pub fn macos_key_code(usage: u16) -> Option<u16> {
    const LETTERS: [u16; 26] = [
        0x00, 0x0b, 0x08, 0x02, 0x0e, 0x03, 0x05, 0x04, 0x22, 0x26, 0x28, 0x25, 0x2e, 0x2d, 0x1f,
        0x23, 0x0c, 0x0f, 0x01, 0x11, 0x20, 0x09, 0x0d, 0x07, 0x10, 0x06,
    ];
    const DIGITS: [u16; 10] = [0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1a, 0x1c, 0x19, 0x1d];
    const FUNCTIONS: [u16; 20] = [
        0x7a, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6d, 0x67, 0x6f, 0x69, 0x6b, 0x71,
        0x6a, 0x40, 0x4f, 0x50, 0x5a,
    ];
    Some(match usage {
        0x04..=0x1d => LETTERS[(usage - 4) as usize],
        0x1e..=0x27 => DIGITS[(usage - 0x1e) as usize],
        0x3a..=0x45 => FUNCTIONS[(usage - 0x3a) as usize],
        0x68..=0x6f => FUNCTIONS[(usage - 0x68 + 12) as usize],
        0x28 => 0x24,
        0x29 => 0x35,
        0x2a => 0x33,
        0x2b => 0x30,
        0x2c => 0x31,
        0x2d => 0x1b,
        0x2e => 0x18,
        0x2f => 0x21,
        0x30 => 0x1e,
        0x31 => 0x2a,
        0x33 => 0x29,
        0x34 => 0x27,
        0x35 => 0x32,
        0x36 => 0x2b,
        0x37 => 0x2f,
        0x38 => 0x2c,
        0x4a => 0x73,
        0x4b => 0x74,
        0x4c => 0x75,
        0x4d => 0x77,
        0x4e => 0x79,
        0x4f => 0x7c,
        0x50 => 0x7b,
        0x51 => 0x7d,
        0x52 => 0x7e,
        _ => return None,
    })
}
