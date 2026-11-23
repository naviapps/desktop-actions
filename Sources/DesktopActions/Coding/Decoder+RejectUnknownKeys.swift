private struct AnyCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int?

  init?(stringValue: String) {
    self.stringValue = stringValue
    self.intValue = nil
  }

  init?(intValue: Int) {
    self.stringValue = "\(intValue)"
    self.intValue = intValue
  }
}

extension Decoder {
  func rejectUnknownKeys<AllowedKey: CodingKey>(
    allowed allowedKeys: [AllowedKey],
    debugName: String
  ) throws {
    let allowedKeyNames = Set(allowedKeys.map(\.stringValue))
    let container = try container(keyedBy: AnyCodingKey.self)

    for key in container.allKeys where !allowedKeyNames.contains(key.stringValue) {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: codingPath + [key],
          debugDescription: "\(debugName) does not accept unknown field \(key.stringValue)."
        )
      )
    }
  }
}
