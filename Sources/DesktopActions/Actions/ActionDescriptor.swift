/// One authoritative Rust catalog entry. Hosts own labels, ordering and localization.
public struct ActionDescriptor: Decodable, Sendable {
  let name: String
  /// The Swift projection of the catalog's typed action name.
  public var kind: ActionKind {
    guard let kind = ActionKind(rawValue: name) else {
      preconditionFailure("The Swift facade does not match the native action catalog.")
    }
    return kind
  }
  public let identifier: String
  public let category: ActionCategory
  public let inputDescriptor: ActionInputDescriptor
  public let inputForm: ActionInputForm
  public let capabilities: ActionKindCapabilities
  public let supportedPlatforms: Set<ActionPlatform>

  private enum CodingKeys: String, CodingKey {
    case name, identifier, category, inputDescriptor, inputForm, capabilities, supportedPlatforms
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)
    guard ActionKind(rawValue: name) != nil else {
      throw DecodingError.dataCorruptedError(
        forKey: .name, in: container, debugDescription: "Unknown native action name.")
    }
    identifier = try container.decode(String.self, forKey: .identifier)
    category = try container.decode(ActionCategory.self, forKey: .category)
    inputDescriptor = try container.decode(ActionInputDescriptor.self, forKey: .inputDescriptor)
    inputForm = try container.decode(ActionInputForm.self, forKey: .inputForm)
    capabilities = try container.decode(ActionKindCapabilities.self, forKey: .capabilities)
    supportedPlatforms = try container.decode(Set<ActionPlatform>.self, forKey: .supportedPlatforms)
  }

}

/// Semantic input forms supplied by Rust, independent of a particular UI toolkit.
public enum ActionInputForm: String, Codable, Hashable, Sendable {
  case none
  case url
  case application
  case shortcut
  case keyboardShortcut = "keyboard-shortcut"
  case folder
  case windowPlacement = "window-placement"
  case windowMove = "window-move"
}
