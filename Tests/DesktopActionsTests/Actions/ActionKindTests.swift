import XCTest

@testable import DesktopActions

final class ActionKindTests: XCTestCase {
  func testSwiftKindOrderMatchesNativeCatalog() throws {
    let catalog = try JSONDecoder().decode(
      [ActionDescriptor].self, from: RustActionJSON.takeCatalog())
    XCTAssertEqual(catalog.map(\.kind), ActionKind.allCases)
  }

  func testActionKindCanBeCreatedFromIdentifier() {
    for kind in ActionKind.allCases {
      XCTAssertEqual(ActionKind(identifier: kind.identifier), kind)
    }

    XCTAssertNil(ActionKind(identifier: "openURL"))
    XCTAssertNil(ActionKind(identifier: "action.workspace.missing"))
  }

  func testActionKindRoundTripsCodableIdentifier() throws {
    for kind in ActionKind.allCases {
      let data = try JSONEncoder().encode(kind)

      XCTAssertEqual(try JSONDecoder().decode(ActionKind.self, from: data), kind)
    }
  }

  func testActionKindCodableUsesIdentifier() throws {
    let data = try JSONEncoder().encode(ActionKind.openURL)

    XCTAssertEqual(String(decoding: data, as: UTF8.self), #""action.workspace.open-url""#)
  }

  func testActionKindCodableRejectsUnsupportedIdentifier() {
    let data = Data(#""openURL""#.utf8)

    XCTAssertThrowsError(try JSONDecoder().decode(ActionKind.self, from: data)) { error in
      guard case DecodingError.dataCorrupted(let context) = error else {
        XCTFail("Expected dataCorrupted, got \(error)")
        return
      }

      XCTAssertTrue(
        context.debugDescription.contains("Unsupported action kind identifier: openURL")
      )
    }
  }
}
