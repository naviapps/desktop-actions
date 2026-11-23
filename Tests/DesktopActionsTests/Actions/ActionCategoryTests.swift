import DesktopActions
import XCTest

final class ActionCategoryTests: XCTestCase {
  func testNativeCatalogProjectsEverySwiftCategory() {
    XCTAssertEqual(Set(ActionKind.allCases.map(\.category)), Set(ActionCategory.allCases))
    XCTAssertEqual(ActionKind.openURL.category, .workspace)
    XCTAssertEqual(ActionKind.captureScreenSelection.category, .system)
  }

  func testActionCategoriesRoundTripCodableRawValue() throws {
    for category in ActionCategory.allCases {
      let data = try JSONEncoder().encode(category)
      XCTAssertEqual(try JSONDecoder().decode(ActionCategory.self, from: data), category)
    }
  }

  func testActionCategoryRawValuesAreCanonical() {
    XCTAssertEqual(
      ActionCategory.allCases.map(\.rawValue),
      [
        "editing",
        "frontmost-application",
        "media",
        "keyboard",
        "workspace",
        "system",
        "window",
      ]
    )
  }
}
