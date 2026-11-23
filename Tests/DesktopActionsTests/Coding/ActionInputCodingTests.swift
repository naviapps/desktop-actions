import DesktopActions
import XCTest

final class ActionInputCodingTests: XCTestCase {
  func testTypedInputsProjectCanonicalNativeValuesAfterRoundtrip() throws {
    let cases: [(input: ActionInput, expected: ActionInput)] = [
      (.string(" \thttps://example.com \n"), .string("https://example.com")),
      (
        .windowPlacement(.init(placement: .fill, display: .displayIdentifier(.max))),
        .windowPlacement(.init(placement: .fill, display: .displayIdentifier(.max)))
      ),
      (
        .windowMove(.init(direction: .previous, preservesRelativePosition: false)),
        .windowMove(.init(direction: .previous, preservesRelativePosition: false))
      ),
    ]
    for (input, expected) in cases {
      let encoded = try JSONEncoder().encode(input)
      let decoded = try JSONDecoder().decode(ActionInput.self, from: encoded)
      XCTAssertEqual(decoded, expected)
    }
  }

  func testStandaloneCodecProjectsNativeErrorsIntoSwift() {
    let data = Data(#"{"shape":"string","value":" "}"#.utf8)
    XCTAssertThrowsError(try JSONDecoder().decode(ActionInput.self, from: data)) {
      guard case DecodingError.dataCorrupted(let context) = $0 else {
        return XCTFail("Expected a data-corrupted error from the Rust codec.")
      }
      XCTAssertTrue(context.underlyingError is ActionCodecError)
    }
    XCTAssertThrowsError(try JSONEncoder().encode(ActionInput.string(" "))) {
      guard case EncodingError.invalidValue(_, let context) = $0 else {
        return XCTFail("Expected an invalid-value error from the Rust codec.")
      }
      XCTAssertTrue(context.underlyingError is ActionCodecError)
    }
  }
}
