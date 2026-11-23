import ApplicationServices
import DesktopActions
import DesktopActionsMacOS
import XCTest

final class ActionExecutorWindowOverviewTests: XCTestCase {
  func testNativeLaunchSkipsPermissionHooksAndSystemEvents() async throws {
    let workspace = TestWorkspace(
      applicationURLForBundleIdentifier: URL(
        fileURLWithPath: "/System/Applications/Mission Control.app"))
    let systemEvents = TestSystemEventsLauncher()
    let keys = TestKeyEventPoster()
    let executor = ActionExecutor(
      configuration: .init(
        permissions: .init(
          ensureAccessibility: {
            XCTFail("Native launch must not require Accessibility")
            return false
          },
          ensureAutomation: {
            XCTFail("Native launch must not require Automation")
            return false
          }
        )),
      dependencies: makeActionExecutorDependencies(
        keyEventPoster: keys, workspace: workspace, systemEventsLauncher: systemEvents))

    let outcome = try await executor.execute(.showWindowOverview)
    let launched = await workspace.applicationLaunchSnapshot
    let systemEventsCalls = await systemEvents.invocationCount

    XCTAssertEqual(outcome.finalResult, .success)
    XCTAssertEqual(outcome.attempts.count, 1)
    XCTAssertEqual(launched.resolvedBundleIdentifiers, ["com.apple.exposelauncher"])
    XCTAssertEqual(launched.openedApplicationURL?.lastPathComponent, "Mission Control.app")
    XCTAssertTrue(keys.postedEvents.isEmpty)
    XCTAssertEqual(systemEventsCalls, 0)
  }

  func testFailedNativeLaunchKeepsTheOrderedAccessibilityFallback() async throws {
    let keys = TestKeyEventPoster()
    let executor = ActionExecutor(
      configuration: .init(
        permissions: .init(
          ensureAccessibility: { true },
          ensureAutomation: {
            XCTFail("Mission Control must not use Automation")
            return false
          }
        )),
      dependencies: makeActionExecutorDependencies(keyEventPoster: keys, workspace: TestWorkspace())
    )

    let outcome = try await executor.execute(.showWindowOverview)

    XCTAssertEqual(outcome.finalResult, .success)
    XCTAssertEqual(outcome.attempts.count, 2)
    XCTAssertEqual(keys.postedEvents.count, 1)
    XCTAssertEqual(keys.postedEvents.first?.virtualKey, 126)
    XCTAssertEqual(keys.postedEvents.first?.flags, .maskControl)
  }
}
