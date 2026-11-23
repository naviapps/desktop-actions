import DesktopActions
import SwiftUI

/// Reusable text entry. All copy, focus, warnings and draft values belong to the host.
public struct ActionTextInputField: View {
  private let kind: ActionTextInputKind
  @Binding private var value: String
  private let placeholder: String
  private let title: Text
  private let focus: FocusState<Bool>.Binding
  private let valueIdentifier: String
  private let keyboardHint: String
  private let keyboardHintIdentifier: String
  private let clearTitle: String
  @Binding private var keyboardWarning: String?

  public init(
    kind: ActionTextInputKind, value: Binding<String>, placeholder: String, title: Text,
    focus: FocusState<Bool>.Binding, valueIdentifier: String,
    keyboardHint: String = "", keyboardHintIdentifier: String = "", clearTitle: String = "",
    keyboardWarning: Binding<String?> = .constant(nil)
  ) {
    self.kind = kind
    self._value = value
    self.placeholder = placeholder
    self.title = title
    self.focus = focus
    self.valueIdentifier = valueIdentifier
    self.keyboardHint = keyboardHint
    self.keyboardHintIdentifier = keyboardHintIdentifier
    self.clearTitle = clearTitle
    self._keyboardWarning = keyboardWarning
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField(placeholder, text: $value)
        .textFieldStyle(.roundedBorder)
        .textContentType(kind.form == .url ? .URL : nil)
        .focused(focus)
        .accessibilityLabel(title)
        .accessibilityIdentifier(valueIdentifier)
        .onChange(of: value) { _, _ in
          if kind.form == .keyboardShortcut { keyboardWarning = nil }
        }

      if kind.form == .keyboardShortcut {
        Text(keyboardHint)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier(keyboardHintIdentifier)
        if let keyboardWarning {
          Text(keyboardWarning)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        HStack {
          Spacer()
          Button(clearTitle) {
            value = ""
            keyboardWarning = nil
          }
          .buttonStyle(.bordered)
          .controlSize(.regular)
          .disabled(value.isEmpty)
        }
      }
    }
  }
}
