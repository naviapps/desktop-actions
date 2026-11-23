import DesktopActions
import DesktopActionsMacOS
import XCTest

@MainActor
final class ActionExecutorCancellationTests: XCTestCase {
  func testCancelledExecutionDoesNotRequestPermissionsOrPostEvents() async {
    let poster = TestKeyEventPoster()
    let executor = ActionExecutor(
      configuration: .init(
        permissions: .init(ensureAccessibility: {
          XCTFail("A cancelled execution must not ask for access")
          return true
        })), dependencies: makeActionExecutorDependencies(keyEventPoster: poster))
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await executor.execute(.copy)
    }
    do {
      _ = try await task.value
      XCTFail("A cancelled execution must throw")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    XCTAssertTrue(poster.postedEvents.isEmpty)
  }

  func testCancellationWhileCheckingPermissionDoesNotRunTheActionOrFallback() async {
    let poster = TestKeyEventPoster()
    let script = RecordingAppleScriptExecutor()
    let executor = ActionExecutor(
      configuration: .init(
        permissions: .init(
          ensureAccessibility: { true },
          ensureAutomation: {
            withUnsafeCurrentTask { $0?.cancel() }
            return true
          })),
      dependencies: makeActionExecutorDependencies(
        keyEventPoster: poster, appleScriptExecutor: script))
    let task = Task { try await executor.execute(.showDesktop) }
    do {
      _ = try await task.value
      XCTFail("Cancellation after a permission check must throw")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    XCTAssertEqual(script.invocationCount, 0)
    XCTAssertTrue(poster.postedEvents.isEmpty)
  }
}
