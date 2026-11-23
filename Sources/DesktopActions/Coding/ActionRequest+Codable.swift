import Foundation
import WindowManagement

extension ActionRequest {
  /// Decodes through the shared codec, then projects the canonical value into Swift cases.
  public init(from decoder: Decoder) throws {
    let wire = try ActionWireValue(from: decoder)
    let data: Data
    do { data = try RustActionJSON.normalize(JSONEncoder().encode(wire)) } catch let error
      as ActionCodecError
    {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: decoder.codingPath,
          debugDescription: error.localizedDescription, underlyingError: error))
    }
    let value = try JSONDecoder().decode(Projection.self, from: data)
    self = try Self(projecting: value)
  }

  // This switch only projects canonical Rust values into typed Swift cases.
  // Creation never calls back into the factory or duplicates input-shape policy.
  init(projecting value: Projection) throws {
    switch value.kind {
    case .minimizeFocusedWindow: self = .minimizeFocusedWindow
    case .toggleFocusedWindowFullScreen: self = .toggleFocusedWindowFullScreen
    case .closeForegroundWindow: self = .closeForegroundWindow
    case .copy: self = .copy
    case .paste: self = .paste
    case .cut: self = .cut
    case .undo: self = .undo
    case .redo: self = .redo
    case .selectAll: self = .selectAll
    case .findInApp: self = .findInApp
    case .hideFrontmostApplication: self = .hideFrontmostApplication
    case .quitFrontmostApplication: self = .quitFrontmostApplication
    case .volumeUp: self = .volumeUp
    case .volumeDown: self = .volumeDown
    case .toggleAudioMute: self = .toggleAudioMute
    case .mediaPlayPause: self = .mediaPlayPause
    case .mediaNext: self = .mediaNext
    case .mediaPrevious: self = .mediaPrevious
    case .showWindowOverview: self = .showWindowOverview
    case .showDesktop: self = .showDesktop
    case .lockScreen: self = .lockScreen
    case .sleepSystem: self = .sleepSystem
    case .switchToNextVirtualDesktop: self = .switchToNextVirtualDesktop
    case .switchToPreviousVirtualDesktop: self = .switchToPreviousVirtualDesktop
    case .missionControlAppExpose: self = .missionControlAppExpose
    case .brightnessUp: self = .brightnessUp
    case .brightnessDown: self = .brightnessDown
    case .toggleAppearance: self = .toggleAppearance
    case .showNotificationCenter: self = .showNotificationCenter
    case .captureScreenFull: self = .captureScreenFull
    case .captureScreenSelection: self = .captureScreenSelection
    case .captureScreenWindow: self = .captureScreenWindow
    case .keyboardShortcut: self = .keyboardShortcut(try value.stringInput())
    case .openURL: self = .openURL(try value.stringInput())
    case .launchApplication: self = .launchApplication(try value.stringInput())
    case .runShortcut: self = .runShortcut(try value.stringInput())
    case .openFolder: self = .openFolder(try value.stringInput())
    case .windowPlacement:
      guard case .windowPlacement(let request)? = value.input else {
        throw ActionCodecError.invalidData("Native window placement projection mismatch.")
      }
      self = .windowPlacement(request)
    case .windowMove:
      guard case .windowMove(let request)? = value.input else {
        throw ActionCodecError.invalidData("Native window movement projection mismatch.")
      }
      self = .windowMove(request)
    }
  }

  /// Encodes the Rust-normalized action through the caller's Codable container.
  public func encode(to encoder: Encoder) throws {
    let raw = try JSONEncoder().encode(Projection(kind: kind, input: input))
    let canonical: Data
    do { canonical = try RustActionJSON.normalize(raw) } catch let error as ActionCodecError {
      throw EncodingError.invalidValue(
        self,
        .init(
          codingPath: encoder.codingPath,
          debugDescription: error.localizedDescription, underlyingError: error))
    }
    try JSONDecoder().decode(ActionWireValue.self, from: canonical).encode(to: encoder)
  }

  struct Projection: Codable {
    let kind: ActionKind
    let input: ActionInput?
    enum CodingKeys: String, CodingKey { case kind, input }

    init(kind: ActionKind, input: ActionInput?) {
      self.kind = kind
      self.input = input
    }
    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      kind = try c.decode(ActionKind.self, forKey: .kind)
      switch kind.inputDescriptor.shape {
      case .none: input = nil
      case .string: input = try .string(c.decode(String.self, forKey: .input))
      case .windowPlacement:
        input = try .windowPlacement(c.decode(WindowPlacementRequest.self, forKey: .input))
      case .windowMove: input = try .windowMove(c.decode(WindowMoveRequest.self, forKey: .input))
      }
    }
    func stringInput() throws -> String {
      guard case .string(let value)? = input else {
        throw ActionCodecError.invalidData("Native string input projection mismatch.")
      }
      return value
    }
    func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(kind, forKey: .kind)
      switch input {
      case .none: break
      case .string(let v): try c.encode(v, forKey: .input)
      case .windowPlacement(let v): try c.encode(v, forKey: .input)
      case .windowMove(let v): try c.encode(v, forKey: .input)
      }
    }
  }
}
