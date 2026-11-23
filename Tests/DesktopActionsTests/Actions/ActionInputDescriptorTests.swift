import DesktopActions
import XCTest

final class ActionInputDescriptorTests: XCTestCase {
  func testCatalogProjectsInputFreeAndTypedExamples() throws {
    let inputFree = ActionKind.copy.inputDescriptor
    XCTAssertFalse(inputFree.requiresInput)
    XCTAssertNil(inputFree.parameter)

    let descriptor = ActionKind.openURL.inputDescriptor
    XCTAssertTrue(descriptor.requiresInput)
    let example = try XCTUnwrap(descriptor.exampleInput)
    XCTAssertEqual(descriptor.shape, .string)
    XCTAssertEqual(ActionKind.openURL.makeAction(input: example), .openURL("https://example.com"))
  }

  func testHostMetadataUsesTheRustCodecThroughFailableInitAndCodable() throws {
    let parameter = try XCTUnwrap(
      ActionInputParameter(
        name: " \u{200b}url ", description: "\nURL string.\t",
        exampleInput: .string("  https://example.com  ")))
    XCTAssertEqual(parameter.name, "url")
    XCTAssertEqual(parameter.description, "URL string.")
    XCTAssertEqual(parameter.exampleInput, .string("https://example.com"))

    let descriptor = try XCTUnwrap(ActionInputDescriptor(shape: .string, parameter: parameter))
    let encoded = try JSONEncoder().encode(descriptor)
    XCTAssertEqual(try JSONDecoder().decode(ActionInputDescriptor.self, from: encoded), descriptor)
    XCTAssertNil(ActionInputDescriptor(shape: .windowPlacement, parameter: parameter))
  }

  func testParameterLabelsKeepExactUTF8Identity() throws {
    let composed = "caf\u{e9}"
    let decomposed = "cafe\u{301}"
    let example = ActionInput.string("example")
    let parameter = try XCTUnwrap(
      ActionInputParameter(name: composed, description: composed, exampleInput: example))
    let differentName = try XCTUnwrap(
      ActionInputParameter(name: decomposed, description: composed, exampleInput: example))
    let differentDescription = try XCTUnwrap(
      ActionInputParameter(name: composed, description: decomposed, exampleInput: example))
    XCTAssertEqual(Set([parameter, differentName, differentDescription]).count, 3)
  }

  func testDecoderPreservesNativeMetadataError() {
    let bytes = Data(#"{"shape":"none","parameter":null}"#.utf8)
    XCTAssertThrowsError(try JSONDecoder().decode(ActionInputDescriptor.self, from: bytes)) {
      guard case DecodingError.dataCorrupted(let context) = $0 else {
        return XCTFail("Expected a data-corrupted error from the Rust codec.")
      }
      XCTAssertTrue(context.underlyingError is ActionCodecError)
    }
  }
}
