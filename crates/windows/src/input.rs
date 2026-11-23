// Pure Windows keyboard transaction description, exercised without posting input.
use desktop_actions::ModifierFlags;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Key {
    Virtual(u16),
    Scan { code: u16, extended: bool },
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Edge {
    pub key: Key,
    pub up: bool,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InputError {
    InvalidModifiers,
    ConflictingState,
}

/// Exclude modifiers held by the user from both insertion and recovery. Additional
/// held modifiers or an already-pressed main key make this transaction ambiguous.
pub fn transaction(
    key: Key,
    modifiers: u16,
    held: u16,
    key_down: bool,
) -> Result<Vec<Edge>, InputError> {
    if modifiers & !15 != 0 {
        return Err(InputError::InvalidModifiers);
    }
    if held & !modifiers != 0 || key_down {
        return Err(InputError::ConflictingState);
    }
    let mut events = Vec::new();
    let mut pressed = Vec::new();
    for (flag, vk) in [
        (ModifierFlags::META, 0x5b),
        (ModifierFlags::CONTROL, 0xa2),
        (ModifierFlags::ALT, 0xa4),
        (ModifierFlags::SHIFT, 0xa0),
    ] {
        if modifiers & flag != 0 && held & flag == 0 {
            let key = Key::Virtual(vk);
            events.push(Edge { key, up: false });
            pressed.push(key);
        }
    }
    events.push(Edge { key, up: false });
    events.push(Edge { key, up: true });
    events.extend(pressed.into_iter().rev().map(|key| Edge { key, up: true }));
    Ok(events)
}
/// Recovery is the inverse of the accepted prefix, never an arbitrary release of
/// the global keyboard state. Completed up edges remove their ownership first.
pub fn recovery(events: &[Edge], inserted: usize) -> Vec<Edge> {
    let mut pressed = Vec::new();
    for edge in events.iter().take(inserted) {
        if edge.up {
            pressed.retain(|key| key != &edge.key);
        } else if !pressed.contains(&edge.key) {
            pressed.push(edge.key);
        }
    }
    pressed
        .into_iter()
        .rev()
        .map(|key| Edge { key, up: true })
        .collect()
}
#[derive(Debug, PartialEq, Eq)]
pub struct PostFailure {
    pub insertion_error: u32,
    pub cleanup_error: Option<u32>,
}
/// Complete partial key-up batches while they make progress. A zero insertion
/// stops recovery rather than spinning indefinitely against a blocked desktop.
pub fn insert(
    events: &[Edge],
    mut send: impl FnMut(&[Edge]) -> (usize, u32),
) -> Result<(), PostFailure> {
    let (inserted, insertion_error) = send(events);
    if inserted == events.len() {
        return Ok(());
    }
    let mut pending = recovery(events, inserted);
    while !pending.is_empty() {
        let (released, error) = send(&pending);
        if released == 0 || released > pending.len() {
            return Err(PostFailure {
                insertion_error,
                cleanup_error: Some(error),
            });
        }
        pending.drain(..released);
    }
    Err(PostFailure {
        insertion_error,
        cleanup_error: None,
    })
}
/// USB HID keyboard usage to US-ANSI Set 1 physical position. Extended navigation
/// keys retain their E0 prefix, independently of the active character layout.
pub fn scan(usage: u16) -> Option<Key> {
    const LETTERS: [u16; 26] = [
        0x1e, 0x30, 0x2e, 0x20, 0x12, 0x21, 0x22, 0x23, 0x17, 0x24, 0x25, 0x26, 0x32, 0x31, 0x18,
        0x19, 0x10, 0x13, 0x1f, 0x14, 0x16, 0x2f, 0x11, 0x2d, 0x15, 0x2c,
    ];
    let (code, extended) = match usage {
        0x04..=0x1d => (LETTERS[(usage - 4) as usize], false),
        0x1e..=0x26 => (usage - 0x1e + 2, false),
        0x27 => (0x0b, false),
        0x3a..=0x43 => (usage - 0x3a + 0x3b, false),
        0x44 => (0x57, false),
        0x45 => (0x58, false),
        0x68..=0x72 => (usage - 0x68 + 0x64, false),
        0x73 => (0x76, false),
        0x28 => (0x1c, false),
        0x29 => (1, false),
        0x2a => (0x0e, false),
        0x2b => (0x0f, false),
        0x2c => (0x39, false),
        0x2d => (0x0c, false),
        0x2e => (0x0d, false),
        0x2f => (0x1a, false),
        0x30 => (0x1b, false),
        0x31 => (0x2b, false),
        0x33 => (0x27, false),
        0x34 => (0x28, false),
        0x35 => (0x29, false),
        0x36 => (0x33, false),
        0x37 => (0x34, false),
        0x38 => (0x35, false),
        0x4a => (0x47, true),
        0x4b => (0x49, true),
        0x4c => (0x53, true),
        0x4d => (0x4f, true),
        0x4e => (0x51, true),
        0x4f => (0x4d, true),
        0x50 => (0x4b, true),
        0x51 => (0x50, true),
        0x52 => (0x48, true),
        _ => return None,
    };
    Some(Key::Scan { code, extended })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn every_partial_prefix_recovers_only_owned_keys_in_reverse_order() {
        let events = transaction(Key::Virtual(0x43), 9, 8, false).unwrap();
        assert_eq!(events[0].key, Key::Virtual(0x5b));
        for count in 0..=events.len() {
            let mut combined = events[..count].to_vec();
            combined.extend(recovery(&events, count));
            assert!(recovery(&combined, combined.len()).is_empty());
            assert!(
                !combined.iter().any(|e| e.key == Key::Virtual(0xa2)),
                "Held Control was changed"
            );
        }
        assert_eq!(
            transaction(Key::Virtual(0x43), 8, 2, false),
            Err(InputError::ConflictingState)
        );
        assert_eq!(
            transaction(Key::Virtual(0x43), 8, 0, true),
            Err(InputError::ConflictingState)
        );
        assert_eq!(
            transaction(Key::Virtual(0x43), 16, 0, false),
            Err(InputError::InvalidModifiers)
        );
    }
    #[test]
    fn physical_navigation_function_keys_and_punctuation_have_explicit_positions() {
        assert_eq!(
            scan(4),
            Some(Key::Scan {
                code: 0x1e,
                extended: false
            })
        );
        assert_eq!(
            scan(0x4e),
            Some(Key::Scan {
                code: 0x51,
                extended: true
            })
        );
        assert_eq!(
            scan(0x73),
            Some(Key::Scan {
                code: 0x76,
                extended: false
            })
        );
        assert_eq!(scan(0xffff), None);
    }
    #[test]
    fn partial_insertion_and_partial_cleanup_progress_are_acknowledged_separately() {
        let events = transaction(Key::Virtual(0x43), 9, 8, false).unwrap();
        for accepted in 0..events.len() {
            let mut sent = Vec::new();
            let mut first = true;
            let result = insert(&events, |batch| {
                let count = if first {
                    first = false;
                    accepted
                } else {
                    1
                };
                sent.extend_from_slice(&batch[..count]);
                (count, 5)
            });
            assert_eq!(
                result,
                Err(PostFailure {
                    insertion_error: 5,
                    cleanup_error: None
                })
            );
            assert!(recovery(&sent, sent.len()).is_empty());
            assert!(!sent.iter().any(|e| e.key == Key::Virtual(0xa2)));
        }
        let mut first = true;
        assert_eq!(
            insert(&events, |_| if first {
                first = false;
                (1, 5)
            } else {
                (0, 87)
            }),
            Err(PostFailure {
                insertion_error: 5,
                cleanup_error: Some(87)
            })
        );
    }
}
