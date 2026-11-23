import DesktopActions
import XCTest

final class ActionPreflightMediaTests: XCTestCase {
  func testConsumerControlsUseDedicatedSystemKeys() {
    let cases: [(ActionRequest, UInt16)] = [
      (.volumeUp, 0), (.volumeDown, 1), (.toggleAudioMute, 7), (.mediaPlayPause, 16),
      (.mediaNext, 17), (.mediaPrevious, 18), (.brightnessUp, 2), (.brightnessDown, 3),
    ]
    for (action, code) in cases {
      let plan = ActionPreflight.plan(for: action)
      XCTAssertEqual(plan.steps.map(\.method), [.systemKey(code)])
      XCTAssertEqual(plan.permissionRequirements, .init(primary: [.accessibility], fallback: []))
    }
  }
}
