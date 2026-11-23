/// Compares and hashes the exact UTF-8 spelling retained by Rust strings.
struct UTF8Text: Hashable {
  let value: String

  init(_ value: String) {
    self.value = value
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.value.utf8.elementsEqual(rhs.value.utf8)
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(value.utf8.count)
    for byte in value.utf8 { hasher.combine(byte) }
  }
}
