import SwiftUI

/// A read-only selection display with caller-supplied choices and native picker commands.
/// It does not enumerate applications, present panels or retain a selection.
public struct ActionSelectionInput<Choices: View>: View {
  private let value: String
  private let placeholder: String
  private let choices: Choices

  public init(value: String, placeholder: String, @ViewBuilder choices: () -> Choices) {
    self.value = value
    self.placeholder = placeholder
    self.choices = choices()
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField(placeholder, text: .constant(value))
        .textFieldStyle(.roundedBorder)
        .foregroundStyle(value.isEmpty ? .secondary : .primary)
        .disabled(true)
      choices
    }
  }
}

/// Lists an injected Shortcut catalog. Loading, failures and retry policy remain host-owned.
public struct ActionShortcutMenu: View {
  private let names: [String]
  @Binding private var value: String
  private let title: String

  public init(names: [String], value: Binding<String>, title: String) {
    self.names = names
    self._value = value
    self.title = title
  }

  public var body: some View {
    Menu {
      ForEach(Array(names.enumerated()), id: \.offset) { _, name in
        Button(name) { value = name }
      }
    } label: {
      Label(title, systemImage: "list.bullet")
    }
    .menuStyle(.borderlessButton)
    .labelStyle(.titleAndIcon)
  }
}
