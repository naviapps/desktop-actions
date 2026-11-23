import Foundation

/// A catalog kind with text input. This holds no draft, persistence or native resources.
public struct ActionTextInputKind: Hashable, Identifiable, Sendable {
  public let kind: ActionKind
  public var id: String { kind.identifier }
  public var form: ActionInputForm { kind.descriptor.inputForm }

  public init?(kind: ActionKind) {
    guard kind.inputDescriptor.shape == .string else { return nil }
    self.kind = kind
  }

  public func makeAction(input: String) -> ActionRequest? {
    kind.makeAction(input: .string(input))
  }

  /// Inspects a draft without changing it. Native observations are optional and injected.
  /// An absent or empty Shortcut catalog permits manual entry. Directory lookup is called
  /// only for a nonempty normalized folder path, never for an unrelated form.
  public func evaluate(
    _ value: String,
    platform: ActionPlatform = .macOS,
    shortcuts: [String]? = nil,
    directoryExists: ((String) -> Bool)? = nil
  ) -> ActionTextInputEvaluation {
    func evaluate(directoryExists: Bool?) -> ActionTextInputEvaluation {
      let request = Request(
        identifier: id, value: value, platform: platform, shortcuts: shortcuts,
        directoryExists: directoryExists)
      do {
        let data = try RustActionJSON.evaluateTextInput(JSONEncoder().encode(request))
        return try JSONDecoder().decode(ActionTextInputEvaluation.self, from: data)
      } catch {
        preconditionFailure("Invalid native text-input evaluation: \(error)")
      }
    }
    let result = evaluate(directoryExists: nil)
    guard form == .folder, result.canConfirm, let directoryExists else {
      return result
    }
    return evaluate(directoryExists: directoryExists(result.normalizedValue))
  }

  private struct Request: Encodable {
    let identifier: String
    let value: String
    let platform: ActionPlatform
    let shortcuts: [String]?
    let directoryExists: Bool?
  }
}

/// A proposed confirmation and portable validation issue. The caller retains the original draft.
public struct ActionTextInputEvaluation: Decodable, Equatable, Sendable {
  public let normalizedValue: String
  public let confirmedValue: String
  public let issue: ActionTextInputIssue?
  public let canConfirm: Bool
}

/// Hosts translate these shared issues into their own localized feedback.
public enum ActionTextInputIssue: String, Decodable, Sendable {
  case invalidInput = "invalid-input"
  case unsupportedPlatform = "unsupported-platform"
  case invalidURL = "invalid-url"
  case invalidKeyboardShortcut = "invalid-keyboard-shortcut"
  case directoryUnavailable = "directory-unavailable"
  case shortcutNotFound = "shortcut-not-found"
  case ambiguousShortcut = "ambiguous-shortcut"
}
