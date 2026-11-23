import DesktopActions
import XCTest

final class ActionInputShapeTests: XCTestCase {
  func testActionInputShapeRoundTripsCodable() throws {
    for inputShape in ActionInputShape.allCases {
      let data = try JSONEncoder().encode(inputShape)
      XCTAssertEqual(try JSONDecoder().decode(ActionInputShape.self, from: data), inputShape)
    }
  }

  func testActionInputShapeRawValuesAreCanonical() {
    XCTAssertEqual(
      ActionInputShape.allCases.map(\.rawValue),
      [
        "none",
        "string",
        "window-placement",
        "window-move",
      ]
    )
  }
}
