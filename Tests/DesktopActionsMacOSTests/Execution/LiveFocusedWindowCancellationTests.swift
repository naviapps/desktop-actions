import DesktopActions
import Foundation
import WindowManagement
import WindowManagementMacOS
import XCTest

@testable import DesktopActionsMacOS

final class LiveFocusedWindowCancellationTests: XCTestCase {
  private static let placement = WindowPlacementRequest(placement: .fill, inset: 12)
  private static let move = WindowMoveRequest(
    direction: .previous, preservesRelativePosition: false)
  private static let operations: [WindowingExecution] = [
    .closeForegroundWindow, .minimizeFocusedWindow, .toggleFocusedWindowFullScreen,
    .placeFocusedWindow(placement), .moveFocusedWindow(move),
  ]

  func testUncancelledAdapterForwardsEveryOperationAndRequest() async throws {
    let effects = InvocationRecorder()
    let controller = LiveFocusedWindowController(
      requestClose: { effects.record() },
      minimize: { effects.record() },
      toggleFullScreen: { effects.record() },
      place: { request in
        XCTAssertEqual(request, Self.placement)
        effects.record()
      },
      moveToAdjacentDisplay: { request in
        XCTAssertEqual(request, Self.move)
        effects.record()
      })

    try await controller.requestClose()
    try await controller.minimize()
    try await controller.toggleFullScreen()
    try await controller.place(Self.placement)
    try await controller.moveToAdjacentDisplay(Self.move)

    XCTAssertEqual(effects.invocationCount, Self.operations.count)
  }

  func testAlreadyCancelledAdapterSkipsEveryNativeOperation() async throws {
    let effects = InvocationRecorder()
    let controller = Self.controller(recording: effects)
    let placement = Self.placement
    let move = Self.move
    let task = Task.detached { @Sendable in
      withUnsafeCurrentTask { $0?.cancel() }
      try await controller.requestClose()
      try await controller.minimize()
      try await controller.toggleFullScreen()
      try await controller.place(placement)
      try await controller.moveToAdjacentDisplay(move)
    }

    try await task.value

    XCTAssertEqual(effects.invocationCount, 0)
  }

  func testCancellationWhileQueuedToMainActorSkipsEffectsLogsAndFallback() async {
    for operation in Self.operations {
      let effects = InvocationRecorder()
      let logs = InvocationRecorder()
      let keys = TestKeyEventPoster()
      let reachedController = expectation(description: "Executor reached the controller factory")
      let releaseController = DispatchSemaphore(value: 0)
      let leavingFactory = DispatchSemaphore(value: 0)
      let controller = Self.controller(recording: effects)
      let executor = Self.executor(
        logs: logs, keys: keys,
        makeController: {
          reachedController.fulfill()
          XCTAssertEqual(releaseController.wait(timeout: .now() + 2), .success)
          leavingFactory.signal()
          return controller
        })
      let plan = Self.plan(operation)
      let task = Task.detached { @Sendable in try await executor.execute(plan: plan) }
      await fulfillment(of: [reachedController], timeout: 2)
      await MainActor.run {
        // Permission callbacks have finished. Hold MainActor while the controller is returned.
        releaseController.signal()
        XCTAssertEqual(leavingFactory.wait(timeout: .now() + 2), .success)
        task.cancel()
      }

      await Self.assertCancelled(task)

      XCTAssertEqual(effects.invocationCount, 0, "\(operation)")
      XCTAssertEqual(logs.invocationCount, 0, "\(operation)")
      XCTAssertTrue(keys.postedEvents.isEmpty, "\(operation)")
    }
  }

  func testCancellationDuringNativeFailureDoesNotLogOrRunFallback() async {
    for operation in Self.operations {
      let logs = InvocationRecorder()
      let keys = TestKeyEventPoster()
      let controller = LiveFocusedWindowController(
        requestClose: { try Self.cancelAndFail() },
        minimize: { try Self.cancelAndFail() },
        toggleFullScreen: { try Self.cancelAndFail() },
        place: { _ in try Self.cancelAndFail() },
        moveToAdjacentDisplay: { _ in try Self.cancelAndFail() })
      let executor = Self.executor(
        logs: logs, keys: keys, makeController: { controller })
      let plan = Self.plan(operation)
      let task = Task { @Sendable in try await executor.execute(plan: plan) }

      await Self.assertCancelled(task)

      XCTAssertEqual(logs.invocationCount, 0, "\(operation)")
      XCTAssertTrue(keys.postedEvents.isEmpty, "\(operation)")
    }
  }

  func testUncancelledNativeFailureStillLogsAndRunsFallback() async throws {
    for operation in Self.operations {
      let logs = InvocationRecorder()
      let keys = TestKeyEventPoster()
      let controller = LiveFocusedWindowController(
        requestClose: {
          throw WindowAccessibilityError.unsupportedAccessibilityOperation(.requestClose)
        },
        minimize: { throw WindowAccessibilityError.unsupportedAccessibilityOperation(.setFrame) },
        toggleFullScreen: {
          throw WindowAccessibilityError.unsupportedAccessibilityOperation(.setFullScreen)
        },
        place: { _ in throw WindowAccessibilityError.unsupportedAccessibilityOperation(.setFrame) },
        moveToAdjacentDisplay: { _ in
          throw WindowAccessibilityError.unsupportedAccessibilityOperation(.setFrame)
        })
      let executor = Self.executor(
        logs: logs, keys: keys, makeController: { controller })

      let report = try await executor.execute(plan: Self.plan(operation))

      XCTAssertEqual(report.finalResult, .success)
      XCTAssertEqual(report.attempts.count, 2)
      XCTAssertEqual(logs.invocationCount, 1, "\(operation)")
      XCTAssertFalse(keys.postedEvents.isEmpty, "\(operation)")
    }
  }

  private static func controller(recording effects: InvocationRecorder)
    -> LiveFocusedWindowController
  {
    LiveFocusedWindowController(
      requestClose: { effects.record() },
      minimize: { effects.record() },
      toggleFullScreen: { effects.record() },
      place: { _ in effects.record() },
      moveToAdjacentDisplay: { _ in effects.record() })
  }

  private static func executor(
    logs: InvocationRecorder,
    keys: TestKeyEventPoster,
    makeController: @escaping @Sendable () -> any FocusedWindowControlling
  ) -> ActionExecutor {
    ActionExecutor(
      configuration: .init(
        permissions: .init(ensureAccessibility: { true }),
        log: { _, _ in logs.record() }),
      dependencies: makeActionExecutorDependencies(
        keyEventPoster: keys, makeFocusedWindowController: makeController))
  }

  private static func plan(_ operation: WindowingExecution) -> ActionPlan {
    .init(steps: [
      .init(method: .windowing(operation)),
      .init(method: .keyEvent(virtualKeyCode: 0), isFallback: true),
    ])
  }

  private static func cancelAndFail() throws {
    withUnsafeCurrentTask { $0?.cancel() }
    throw WindowAccessibilityError.unsupportedAccessibilityOperation(.setFrame)
  }

  private static func assertCancelled(
    _ task: Task<ActionExecutionReport, any Error>,
    file: StaticString = #filePath, line: UInt = #line
  ) async {
    do {
      _ = try await task.value
      XCTFail("Cancelled window operation must throw", file: file, line: line)
    } catch {
      XCTAssertTrue(error is CancellationError, file: file, line: line)
    }
  }
}
