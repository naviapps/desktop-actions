import DesktopActions
import XCTest

@testable import DesktopActionsMacOS

final class LiveFrontmostApplicationCancellationTests: XCTestCase {
  func testNativeAdapterInvokesUncancelledHideAndTerminate() async {
    let effects = InvocationRecorder()
    let controller = LiveFrontmostApplicationController(
      hideFrontmost: {
        effects.record()
        return .success
      },
      terminateFrontmost: {
        effects.record()
        return .success
      })
    let hidden = await controller.hideFrontmostApplication()
    let terminated = await controller.terminateFrontmostApplication()
    XCTAssertEqual(hidden, .success)
    XCTAssertEqual(terminated, .success)
    XCTAssertEqual(effects.invocationCount, 2)
  }

  func testCancelledNativeAdapterNeverInvokesHideOrTerminateAfterActorHop() async {
    let effects = InvocationRecorder()
    let controller = LiveFrontmostApplicationController(
      hideFrontmost: {
        effects.record()
        return .success
      },
      terminateFrontmost: {
        effects.record()
        return .success
      })
    let task = Task.detached {
      withUnsafeCurrentTask { $0?.cancel() }
      _ = await controller.hideFrontmostApplication()
      _ = await controller.terminateFrontmostApplication()
    }
    await task.value
    XCTAssertEqual(effects.invocationCount, 0)
  }

  func testCancellationWhileControllingFrontmostApplicationDoesNotLogNativeFailure() async {
    for method: ActionMethod in [.hideFrontmostApplication, .terminateFrontmostApplication] {
      let logs = InvocationRecorder()
      let executor = ActionExecutor(
        configuration: .init(log: { _, _ in logs.record() }),
        dependencies: makeActionExecutorDependencies(
          frontmostApplicationController: CancellingFrontmostApplicationController()))
      let task = Task {
        try await executor.execute(plan: .init(steps: [.init(method: method)]))
      }
      do {
        _ = try await task.value
        XCTFail("Cancelled application control must throw")
      } catch {
        XCTAssertTrue(error is CancellationError)
      }
      XCTAssertEqual(logs.invocationCount, 0)
    }
  }
}

private struct CancellingFrontmostApplicationController: FrontmostApplicationControlling {
  func hideFrontmostApplication() async -> FrontmostApplicationControlResult {
    withUnsafeCurrentTask { $0?.cancel() }
    return .failed
  }
  func terminateFrontmostApplication() async -> FrontmostApplicationControlResult {
    withUnsafeCurrentTask { $0?.cancel() }
    return .failed
  }
}
