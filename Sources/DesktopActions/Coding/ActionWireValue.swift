import Foundation

/// A Codable projection only. Rust owns action semantics and normalization.
indirect enum ActionWireValue: Codable {
  case object([String: ActionWireValue])
  case array([ActionWireValue])
  case string(String)
  case integer(Int64)
  case unsigned(UInt64)
  case number(Double)
  case bool(Bool)
  case null

  init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer()
    if value.decodeNil() {
      self = .null
    } else if let v = try? value.decode(Bool.self) {
      self = .bool(v)
    } else if let v = try? value.decode(Int64.self) {
      self = .integer(v)
    } else if let v = try? value.decode(UInt64.self) {
      self = .unsigned(v)
    } else if let v = try? value.decode(Double.self) {
      self = .number(v)
    } else if let v = try? value.decode(String.self) {
      self = .string(v)
    } else if let v = try? value.decode([String: Self].self) {
      self = .object(v)
    } else {
      self = try .array(value.decode([Self].self))
    }
  }
  func encode(to encoder: Encoder) throws {
    var value = encoder.singleValueContainer()
    switch self {
    case .object(let v): try value.encode(v)
    case .array(let v): try value.encode(v)
    case .string(let v): try value.encode(v)
    case .integer(let v): try value.encode(v)
    case .unsigned(let v): try value.encode(v)
    case .number(let v): try value.encode(v)
    case .bool(let v): try value.encode(v)
    case .null: try value.encodeNil()
    }
  }
  static func project<T: Encodable>(_ value: T) throws -> Self {
    try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
  }
  func decode<T: Decodable>(_ type: T.Type) throws -> T {
    try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
  }
}
