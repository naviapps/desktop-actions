import Foundation

extension ActionKind {
  /// The authoritative Rust catalog descriptor for this kind.
  public var descriptor: ActionDescriptor { metadata }

  /// Canonical identifier for registries, persistence and tool surfaces.
  public var identifier: String { metadata.identifier }
  /// Catalog category for the action kind.
  public var category: ActionCategory { metadata.category }
  /// Required-input metadata for host UIs and tool surfaces.
  public var inputDescriptor: ActionInputDescriptor { metadata.inputDescriptor }
  /// Conservative host-policy hints; native preflight still determines availability.
  public var capabilities: ActionKindCapabilities { metadata.capabilities }
  /// Platforms with a plan for this kind. Does not establish valid input, permission,
  /// an installed target or successful native execution.
  public var supportedPlatforms: Set<ActionPlatform> { metadata.supportedPlatforms }

  /// Creates a kind from its canonical persistence identifier.
  public init?(identifier: String) {
    guard let item = NativeActionCatalog.byIdentifier[identifier],
      let kind = Self(rawValue: item.name)
    else { return nil }
    self = kind
  }

  private var metadata: ActionDescriptor {
    guard let item = NativeActionCatalog.byName[rawValue] else {
      preconditionFailure("The Swift action facade does not match its native catalog.")
    }
    return item
  }
}

private enum NativeActionCatalog {
  private static let items: [ActionDescriptor] = {
    do {
      return try JSONDecoder().decode([ActionDescriptor].self, from: RustActionJSON.takeCatalog())
    } catch {
      preconditionFailure("Invalid embedded action catalog: \(error)")
    }
  }()
  static let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
  static let byIdentifier = Dictionary(uniqueKeysWithValues: items.map { ($0.identifier, $0) })
}
