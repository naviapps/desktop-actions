import DesktopActions
import XCTest

final class ActionKindCapabilitiesTests: XCTestCase {
  func testCatalogProjectsBothPlatformSupportOutcomes() {
    XCTAssertEqual(ActionKind.showWindowOverview.supportedPlatforms, [.macOS, .windows])
    XCTAssertEqual(ActionKind.sleepSystem.supportedPlatforms, [.macOS])
  }

  func testActionRetryBehaviorRawValuesAreCanonical() {
    XCTAssertEqual(
      ActionRetryBehavior.allCases.map(\.rawValue),
      ["safe", "context-dependent", "unsafe"]
    )
  }

  func testActionRetryBehaviorRoundTripsCodable() throws {
    for retryBehavior in ActionRetryBehavior.allCases {
      let data = try JSONEncoder().encode(retryBehavior)

      XCTAssertEqual(try JSONDecoder().decode(ActionRetryBehavior.self, from: data), retryBehavior)
    }
  }

  func testDefaultCapabilitiesAreConservative() {
    let capabilities = ActionKindCapabilities()

    XCTAssertFalse(capabilities.requiresFrontmostApplication)
    XCTAssertFalse(capabilities.requiresFocusedWindow)
    XCTAssertFalse(capabilities.requiresInteractiveSelection)
    XCTAssertFalse(capabilities.isDestructive)
    XCTAssertEqual(capabilities.retryBehavior, .contextDependent)
  }

  func testCatalogProjectsTypedCapabilities() {
    XCTAssertTrue(ActionKind.captureScreenSelection.capabilities.requiresInteractiveSelection)
    XCTAssertEqual(ActionKind.captureScreenSelection.capabilities.retryBehavior, .unsafe)
    XCTAssertFalse(ActionKind.openURL.capabilities.requiresInteractiveSelection)
  }

  func testCapabilitiesRoundTripCodable() throws {
    let capabilities = ActionKind.windowPlacement.capabilities
    let data = try JSONEncoder().encode(capabilities)

    XCTAssertEqual(try JSONDecoder().decode(ActionKindCapabilities.self, from: data), capabilities)
  }

  func testCapabilitiesUseCanonicalCodableShape() throws {
    let capabilities = frontmostApplication(
      isDestructive: true,
      retryBehavior: .contextDependent
    )
    let data = try JSONEncoder().encode(capabilities)
    let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]

    XCTAssertEqual(payload?["requiresFrontmostApplication"] as? Bool, true)
    XCTAssertEqual(payload?["requiresFocusedWindow"] as? Bool, false)
    XCTAssertEqual(payload?["requiresInteractiveSelection"] as? Bool, false)
    XCTAssertEqual(payload?["isDestructive"] as? Bool, true)
    XCTAssertEqual(payload?["retryBehavior"] as? String, "context-dependent")
  }

  func testCapabilitiesDecodeCanonicalCodableShape() throws {
    let data = Data(
      """
      {
        "requiresFrontmostApplication": true,
        "requiresFocusedWindow": false,
        "requiresInteractiveSelection": false,
        "isDestructive": true,
        "retryBehavior": "context-dependent"
      }
      """.utf8
    )

    XCTAssertEqual(
      try JSONDecoder().decode(ActionKindCapabilities.self, from: data),
      frontmostApplication(isDestructive: true, retryBehavior: .contextDependent)
    )
  }

  func testCapabilitiesRejectUnknownFieldsWhenDecoding() throws {
    let data = Data(
      """
      {
        "requiresFrontmostApplication": false,
        "requiresFocusedWindow": true,
        "requiresInteractiveSelection": false,
        "isDestructive": false,
        "retryBehavior": "safe",
        "metadata": {}
      }
      """.utf8
    )

    XCTAssertThrowsError(try JSONDecoder().decode(ActionKindCapabilities.self, from: data)) {
      error in
      guard case DecodingError.dataCorrupted(let context) = error else {
        return XCTFail("Expected dataCorrupted, got \(error)")
      }
      XCTAssertEqual(context.codingPath.map(\.stringValue), ["metadata"])
    }
  }

  private func frontmostApplication(
    isDestructive: Bool = false,
    retryBehavior: ActionRetryBehavior
  ) -> ActionKindCapabilities {
    ActionKindCapabilities(
      requiresFrontmostApplication: true,
      isDestructive: isDestructive,
      retryBehavior: retryBehavior
    )
  }
}
