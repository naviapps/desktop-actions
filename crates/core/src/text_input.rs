use crate::{ActionInput, ActionKind, ActionRequest, InputForm, InputShape, Plan, Platform};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

/// Observations are provided by the caller. Evaluation never lists apps, reads files or posts input.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TextInputRequest {
    pub identifier: String,
    pub value: String,
    pub platform: Platform,
    pub shortcuts: Option<Vec<String>>,
    pub directory_exists: Option<bool>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum TextInputIssue {
    InvalidInput,
    UnsupportedPlatform,
    InvalidUrl,
    InvalidKeyboardShortcut,
    DirectoryUnavailable,
    ShortcutNotFound,
    AmbiguousShortcut,
}

/// Drafts remain caller-owned. These values are proposals for an explicit confirmation only.
#[derive(Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TextInputEvaluation {
    pub normalized_value: String,
    pub confirmed_value: String,
    pub issue: Option<TextInputIssue>,
    pub can_confirm: bool,
}

impl TextInputRequest {
    /// Returns None when the identifier is unknown or describes a non-text input form.
    pub fn evaluate(self) -> Option<TextInputEvaluation> {
        let kind = ActionKind::from_identifier(&self.identifier)?;
        let descriptor = kind.descriptor();
        if descriptor.input_descriptor.shape != InputShape::String {
            return None;
        }
        let mut result = TextInputEvaluation {
            normalized_value: String::new(),
            confirmed_value: String::new(),
            issue: None,
            can_confirm: false,
        };
        if self.value.trim().is_empty() {
            return Some(result);
        }
        let Ok(action) = ActionRequest::new(kind, Some(ActionInput::String(self.value))) else {
            result.issue = Some(TextInputIssue::InvalidInput);
            return Some(result);
        };
        let Some(ActionInput::String(value)) = action.input() else {
            return None;
        };
        result.normalized_value = value.clone();
        result.confirmed_value = value.clone();
        let plan = Plan::for_action(&action, self.platform);
        if plan.steps.is_empty() {
            result.issue = Some(TextInputIssue::UnsupportedPlatform);
        } else if !plan.metadata.is_executable {
            result.issue = Some(match descriptor.input_form {
                InputForm::Url => TextInputIssue::InvalidUrl,
                InputForm::KeyboardShortcut => TextInputIssue::InvalidKeyboardShortcut,
                _ => TextInputIssue::InvalidInput,
            });
        } else {
            match descriptor.input_form {
                InputForm::Folder if self.directory_exists == Some(false) => {
                    result.issue = Some(TextInputIssue::DirectoryUnavailable);
                }
                InputForm::Shortcut => {
                    if let Some(names) = self
                        .shortcuts
                        .filter(|names| !names.is_empty() && !names.contains(value))
                    {
                        let folded = value.to_lowercase();
                        let matches: BTreeSet<_> = names
                            .into_iter()
                            .filter(|name| name.to_lowercase() == folded)
                            .collect();
                        match matches.len() {
                            0 => result.issue = Some(TextInputIssue::ShortcutNotFound),
                            1 => result.confirmed_value = matches.into_iter().next().unwrap(),
                            _ => result.issue = Some(TextInputIssue::AmbiguousShortcut),
                        }
                    }
                }
                _ => {}
            }
        }
        result.can_confirm = result.issue.is_none();
        Some(result)
    }
}
