import Foundation
import WindowManagement

/// Host-supplied input used to create an executable action from an action kind.
///
/// `ActionInput` carries values for action kinds whose ``ActionInputShape`` is not
/// ``ActionInputShape/none``. Use ``ActionKind/makeAction()`` for input-free action kinds.
public enum ActionInput: Codable, Hashable, Sendable {
  /// Kind-specific text input.
  ///
  /// Equality and hashing use the exact UTF-8 bytes. Action creation and coding trim whitespace
  /// and reject empty normalized strings.
  case string(String)
  /// Focused-window placement request.
  case windowPlacement(WindowPlacementRequest)
  /// Focused-window screen movement request.
  case windowMove(WindowMoveRequest)
}

extension ActionInput {
  public static func == (lhs: Self, rhs: Self) -> Bool {
    switch (lhs, rhs) {
    case (.string(let lhs), .string(let rhs)): UTF8Text(lhs) == UTF8Text(rhs)
    case (.windowPlacement(let lhs), .windowPlacement(let rhs)): lhs == rhs
    case (.windowMove(let lhs), .windowMove(let rhs)): lhs == rhs
    default: false
    }
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(shape)
    switch self {
    case .string(let value):
      hasher.combine(UTF8Text(value))
    case .windowPlacement(let request):
      hasher.combine(request)
    case .windowMove(let request):
      hasher.combine(request)
    }
  }

  /// The structural shape represented by this input.
  public var shape: ActionInputShape {
    switch self {
    case .string:
      .string
    case .windowPlacement:
      .windowPlacement
    case .windowMove:
      .windowMove
    }
  }

  var normalized: ActionInput? {
    switch self {
    case .string(let value):
      guard let normalized = Self.normalizedString(value) else {
        return nil
      }
      return .string(normalized)
    case .windowPlacement, .windowMove:
      return self
    }
  }

  static func normalizedString(_ value: String) -> String? {
    let raw = ActionWireValue.object(["shape": .string("string"), "value": .string(value)])
    guard let encoded = try? JSONEncoder().encode(raw),
      let canonical = try? RustActionJSON.normalizeInput(encoded),
      let wire = try? JSONDecoder().decode(ActionWireValue.self, from: canonical),
      case .object(let fields) = wire, case .string(let result) = fields["value"]
    else { return nil }
    return result
  }
}
