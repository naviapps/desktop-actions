use desktop_applications::{ApplicationSnapshot, IdentifierKind, ValidationError, validate_target};

/// A foreground target must carry both a creation token and an executable identity.
/// Window/process agreement also rejects snapshots captured across a focus change.
pub(crate) fn validate_application(
    expected: &ApplicationSnapshot,
    actual: &ApplicationSnapshot,
    window_process: u32,
) -> Result<(), ValidationError> {
    if expected.identity.process_id != window_process {
        return Err(ValidationError::TargetChanged);
    }
    if !expected
        .identifier
        .as_ref()
        .is_some_and(|identifier| identifier.kind == IdentifierKind::Executable)
    {
        return Err(ValidationError::IdentifierUnavailable);
    }
    validate_target(expected, actual)
}

/// Read the process behind an observed window and confirm the same window after
/// the process lookup. An incomplete identity never becomes a captured target.
pub(crate) fn capture_application(
    window_process: u32,
    query_application: impl FnOnce(u32) -> Option<ApplicationSnapshot>,
    window_matches: impl FnOnce() -> bool,
) -> Option<ApplicationSnapshot> {
    let application = query_application(window_process)?;
    validate_application(&application, &application, window_process).ok()?;
    window_matches().then_some(application)
}

#[cfg(test)]
mod tests {
    use super::*;
    use desktop_applications::{ApplicationIdentifier, ProcessIdentity};

    fn application() -> ApplicationSnapshot {
        ApplicationSnapshot {
            identity: ProcessIdentity {
                process_id: 42,
                start_time: 100,
            },
            identifier: Some(ApplicationIdentifier {
                kind: IdentifierKind::Executable,
                value: "C:\\fixture.exe".into(),
            }),
            display_name: None,
            terminated: false,
        }
    }

    #[test]
    fn target_requires_same_live_process_creation_executable_and_window_owner() {
        let expected = application();
        assert_eq!(validate_application(&expected, &expected, 42), Ok(()));
        assert_eq!(
            validate_application(&expected, &expected, 43),
            Err(ValidationError::TargetChanged)
        );
        let mut changed = expected.clone();
        changed.identity.start_time += 1;
        assert_eq!(
            validate_application(&expected, &changed, 42),
            Err(ValidationError::TargetChanged)
        );
        changed = expected.clone();
        changed.identifier.as_mut().unwrap().value = "C:\\replacement.exe".into();
        assert_eq!(
            validate_application(&expected, &changed, 42),
            Err(ValidationError::IdentifierMismatch)
        );
        changed = expected.clone();
        changed.terminated = true;
        assert_eq!(
            validate_application(&expected, &changed, 42),
            Err(ValidationError::Terminated)
        );
    }

    #[test]
    fn incomplete_or_non_executable_capture_never_becomes_a_target() {
        let actual = application();
        let mut expected = actual.clone();
        expected.identity.start_time = 0;
        assert_eq!(
            validate_application(&expected, &actual, 42),
            Err(ValidationError::IdentityUnavailable)
        );
        expected = actual.clone();
        expected.identifier = None;
        assert_eq!(
            validate_application(&expected, &actual, 42),
            Err(ValidationError::IdentifierUnavailable)
        );
        expected = actual.clone();
        expected.identifier.as_mut().unwrap().kind = IdentifierKind::AppUserModel;
        assert_eq!(
            validate_application(&expected, &actual, 42),
            Err(ValidationError::IdentifierUnavailable)
        );
    }

    #[test]
    fn capture_requires_a_complete_process_snapshot_and_unchanged_foreground() {
        let expected = application();
        let queried_process = std::cell::Cell::new(false);
        let captured = capture_application(
            expected.identity.process_id,
            |pid| {
                assert_eq!(pid, expected.identity.process_id);
                queried_process.set(true);
                Some(expected.clone())
            },
            || queried_process.get(),
        )
        .unwrap();
        assert_eq!(captured.identity, expected.identity);
        assert!(capture_application(42, |_| Some(expected.clone()), || false).is_none());
        assert!(capture_application(42, |_| None, || true).is_none());
        assert!(capture_application(43, |_| Some(expected.clone()), || true).is_none());
        let mut incomplete = expected;
        incomplete.identity.start_time = 0;
        assert!(capture_application(42, |_| Some(incomplete), || true).is_none());
    }
}
