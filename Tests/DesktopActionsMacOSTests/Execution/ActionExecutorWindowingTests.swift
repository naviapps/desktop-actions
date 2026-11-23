import DesktopActions
import DesktopActionsMacOS
import WindowManagement
import WindowManagementMacOS
import XCTest

final class ActionExecutorWindowingTests: XCTestCase {
  func testCloseRequiresAccessibilityAndRequestsExactlyOneWindowClose() async throws {
    for trusted in [false, true] {
      let recorder = TestFocusedWindowController()
      let executor = ActionExecutor(
        configuration: .init(permissions: .init(ensureAccessibility: { trusted })),
        dependencies: makeActionExecutorDependencies(makeFocusedWindowController: { recorder }))
      let report = try await executor.execute(.closeForegroundWindow)
      XCTAssertEqual(
        report.finalResult, trusted ? .success : .failure(.permissionDenied(.accessibility)))
      XCTAssertEqual(recorder.recordedCloseCalls, trusted ? 1 : 0)
      XCTAssertEqual(recorder.recordedMinimizeCalls, 0)
      XCTAssertEqual(report.attempts.count, 1)
    }
  }

  func testCloseSkipsUnavailableWindowAndDoesNotFallbackWhenCloseIsUnsupported() async throws {
    for error: FocusedWindowControlError in [
      .targetWindowUnavailable, .unsupportedAccessibilityOperation("requestClose"),
    ] {
      let recorder = TestFocusedWindowController(closeError: error)
      let keys = TestKeyEventPoster()
      let executor = ActionExecutor(
        configuration: .init(permissions: .init(ensureAccessibility: { true })),
        dependencies: makeActionExecutorDependencies(
          keyEventPoster: keys, makeFocusedWindowController: { recorder }))
      let report = try await executor.execute(.closeForegroundWindow)
      if error == .targetWindowUnavailable {
        XCTAssertEqual(report.finalResult, .skipped(.noFocusedWindow))
      } else {
        guard case .failure = report.finalResult else { return XCTFail("Expected failure") }
      }
      XCTAssertEqual(report.attempts.count, 1)
      XCTAssertTrue(keys.postedEvents.isEmpty)
    }
  }

  func testMinimizeUsesRustPermissionPlanBeforeCallingWindowController() async throws {
    for trusted in [false, true] {
      let recorder = TestFocusedWindowController()
      let executor = ActionExecutor(
        configuration: .init(permissions: .init(ensureAccessibility: { trusted })),
        dependencies: makeActionExecutorDependencies(makeFocusedWindowController: { recorder }))
      let report = try await executor.execute(.minimizeFocusedWindow)
      XCTAssertEqual(
        report.finalResult, trusted ? .success : .failure(.permissionDenied(.accessibility)))
      XCTAssertEqual(recorder.recordedMinimizeCalls, trusted ? 1 : 0)
    }
  }

  func testMinimizeSkipsUnavailableFocusedWindow() async throws {
    let recorder = TestFocusedWindowController(minimizeError: .targetWindowUnavailable)
    let executor = ActionExecutor(
      configuration: .init(permissions: .init(ensureAccessibility: { true })),
      dependencies: makeActionExecutorDependencies(makeFocusedWindowController: { recorder }))
    let report = try await executor.execute(.minimizeFocusedWindow)
    XCTAssertEqual(report.finalResult, .skipped(.noFocusedWindow))
  }

  func testToggleFullScreenRequiresAccessibilityAndMakesOneNativeRequestWithoutKeys() async throws {
    for trusted in [false, true] {
      let recorder = TestFocusedWindowController()
      let keys = TestKeyEventPoster()
      let factoryInvocations = InvocationRecorder()
      let executor = ActionExecutor(
        configuration: .init(permissions: .init(ensureAccessibility: { trusted })),
        dependencies: makeActionExecutorDependencies(
          keyEventPoster: keys,
          makeFocusedWindowController: {
            factoryInvocations.record()
            return recorder
          }))

      let report = try await executor.execute(.toggleFocusedWindowFullScreen)

      XCTAssertEqual(
        report.finalResult, trusted ? .success : .failure(.permissionDenied(.accessibility)))
      XCTAssertEqual(report.attempts.count, 1)
      XCTAssertEqual(factoryInvocations.invocationCount, trusted ? 1 : 0)
      XCTAssertEqual(recorder.recordedToggleFullScreenCalls, trusted ? 1 : 0)
      XCTAssertTrue(keys.postedEvents.isEmpty)
      XCTAssertTrue(keys.postedSystemKeys.isEmpty)
    }
  }

  func testToggleFullScreenPreservesNoWindowAndUnsupportedResultsWithoutFallback() async throws {
    let cases: [(error: FocusedWindowControlError, result: ActionResult)] = [
      (.targetWindowUnavailable, .skipped(.noFocusedWindow)),
      (
        .unsupportedAccessibilityOperation("setFullScreen"),
        .failure(
          .internalError(
            "Focused-window action failed: unsupported Accessibility window operation: setFullScreen"
          ))
      ),
    ]
    for (error, result) in cases {
      let recorder = TestFocusedWindowController(toggleFullScreenError: error)
      let keys = TestKeyEventPoster()
      let executor = ActionExecutor(
        configuration: .init(permissions: .init(ensureAccessibility: { true })),
        dependencies: makeActionExecutorDependencies(
          keyEventPoster: keys, makeFocusedWindowController: { recorder }))

      let report = try await executor.execute(.toggleFocusedWindowFullScreen)

      XCTAssertEqual(report.finalResult, result)
      XCTAssertEqual(report.attempts.count, 1)
      XCTAssertEqual(recorder.recordedToggleFullScreenCalls, 1)
      XCTAssertTrue(keys.postedEvents.isEmpty)
      XCTAssertTrue(keys.postedSystemKeys.isEmpty)
    }
  }

  func testWindowAccessibilityErrorsMapByPublicErrorCases() {
    XCTAssertEqual(
      FocusedWindowControlError(
        WindowAccessibilityError.applicationUnavailable(.focused)
      ),
      .targetWindowUnavailable
    )
    XCTAssertEqual(
      FocusedWindowControlError(
        WindowAccessibilityError.windowUnavailable(.focused)
      ),
      .targetWindowUnavailable
    )
    XCTAssertEqual(
      FocusedWindowControlError(
        WindowAccessibilityError.unsupportedAccessibilityOperation(.raise)
      ),
      .unsupportedAccessibilityOperation("raise")
    )
    XCTAssertEqual(
      FocusedWindowControlError(
        WindowAccessibilityError.accessibilityOperationFailed(
          operation: .setFrame,
          failure: .cannotComplete
        )
      ),
      .accessibilityOperationFailed("setFrame: cannotComplete")
    )
  }

  func testWindowPlacerErrorsMapToStableInternalClassification() {
    XCTAssertEqual(
      FocusedWindowControlError(
        WindowPlacerError.displayNotFound(.orderedIndex(99))
      ),
      .displayNotFound("orderedIndex(99)")
    )
  }

  func testWindowingExecutionReturnsPermissionDeniedWhenAccessibilityUnavailable() async throws {
    let logs = LogRecorder()
    let factoryInvocations = InvocationRecorder()
    let executor = ActionExecutor(
      configuration: .init(
        permissions: .init(ensureAccessibility: { false }),
        log: { level, message in logs.record(level, message) }
      ),
      dependencies: makeActionExecutorDependencies(makeFocusedWindowController: {
        factoryInvocations.record()
        return TestFocusedWindowController()
      })
    )
    let plan = ActionPlan(steps: [
      .init(method: .windowing(.moveFocusedWindow(.init(direction: .next))))
    ])

    let outcome = try await executor.execute(plan: plan)

    XCTAssertEqual(outcome.finalResult, .failure(.permissionDenied(.accessibility)))
    XCTAssertEqual(factoryInvocations.invocationCount, 0)
    XCTAssertTrue(logs.contains(level: .warning, message: "Permission denied: accessibility"))
  }

  func testWindowPlacementSucceedsWhenControllerAcceptsRequest() async throws {
    let recorder = TestFocusedWindowController()
    let executor = ActionExecutor(
      configuration: .init(permissions: .init(ensureAccessibility: { true })),
      dependencies: makeActionExecutorDependencies(makeFocusedWindowController: { recorder })
    )
    let request = WindowPlacementRequest(
      placement: .grid(columns: 3, rows: 1, column: 0, row: 0, columnSpan: 2, rowSpan: 1),
      display: .orderedIndex(2),
      area: .full,
      inset: 16
    )

    let outcome = try await executor.execute(
      plan: ActionPlan(steps: [
        ActionStep(method: .windowing(.placeFocusedWindow(request)))
      ]))

    XCTAssertEqual(outcome.finalResult, .success)
    XCTAssertEqual(recorder.recordedPlacement, request)
  }

  func testWindowMoveSucceedsWhenControllerAcceptsRequest() async throws {
    let recorder = TestFocusedWindowController()
    let executor = ActionExecutor(
      configuration: .init(permissions: .init(ensureAccessibility: { true })),
      dependencies: makeActionExecutorDependencies(makeFocusedWindowController: { recorder })
    )
    let request = WindowMoveRequest(direction: .previous, preservesRelativePosition: false)

    let outcome = try await executor.execute(
      plan: ActionPlan(steps: [
        ActionStep(method: .windowing(.moveFocusedWindow(request)))
      ]))

    XCTAssertEqual(outcome.finalResult, .success)
    XCTAssertEqual(recorder.recordedMove, request)
  }

  func
    testWindowingExecutionReturnsPermissionDeniedWhenWindowManagementReportsAccessibilityUnavailable()
    async throws
  {
    let logs = LogRecorder()
    let recorder = TestFocusedWindowController(
      placeError: FocusedWindowControlError.accessibilityNotTrusted
    )
    let executor = ActionExecutor(
      configuration: .init(
        permissions: .init(ensureAccessibility: { true }),
        log: { level, message in logs.record(level, message) }
      ),
      dependencies: makeActionExecutorDependencies(makeFocusedWindowController: { recorder })
    )

    let outcome = try await executor.execute(
      plan: ActionPlan(steps: [
        ActionStep(method: .windowing(.placeFocusedWindow(.init(placement: .fill))))
      ]))

    XCTAssertEqual(outcome.finalResult, .failure(.permissionDenied(.accessibility)))
    XCTAssertTrue(logs.contains(level: .warning, message: "Permission denied: accessibility"))
  }

  func testWindowMoveSkipsWhenNoFocusedWindowExists() async throws {
    let recorder = TestFocusedWindowController(
      moveError: FocusedWindowControlError.targetWindowUnavailable
    )
    let executor = ActionExecutor(
      configuration: .init(permissions: .init(ensureAccessibility: { true })),
      dependencies: makeActionExecutorDependencies(makeFocusedWindowController: { recorder })
    )

    let outcome = try await executor.execute(
      plan: ActionPlan(steps: [
        ActionStep(
          method: .windowing(
            .moveFocusedWindow(.init(direction: .previous, preservesRelativePosition: false))))
      ]))

    XCTAssertEqual(outcome.finalResult, .skipped(.noFocusedWindow))
  }

  func testWindowPlacementSkipsWhenFocusedApplicationCannotBeResolved() async throws {
    let recorder = TestFocusedWindowController(
      placeError: FocusedWindowControlError.targetWindowUnavailable
    )
    let executor = ActionExecutor(
      configuration: .init(permissions: .init(ensureAccessibility: { true })),
      dependencies: makeActionExecutorDependencies(makeFocusedWindowController: { recorder })
    )

    let outcome = try await executor.execute(
      plan: ActionPlan(steps: [
        ActionStep(method: .windowing(.placeFocusedWindow(.init(placement: .fill))))
      ]))

    XCTAssertEqual(outcome.finalResult, .skipped(.noFocusedWindow))
  }

  func testWindowPlacementMapsInvalidAXValueToInternalError() async throws {
    let logs = LogRecorder()
    let recorder = TestFocusedWindowController(
      placeError: FocusedWindowControlError.invalidAccessibilityValue("setFrame")
    )
    let executor = ActionExecutor(
      configuration: .init(
        permissions: .init(ensureAccessibility: { true }),
        log: { level, message in logs.record(level, message) }
      ),
      dependencies: makeActionExecutorDependencies(makeFocusedWindowController: { recorder })
    )

    let outcome = try await executor.execute(
      plan: ActionPlan(steps: [
        ActionStep(method: .windowing(.placeFocusedWindow(.init(placement: .fill))))
      ]))

    guard case .failure(let error) = outcome.finalResult else {
      return XCTFail("Expected failure")
    }
    XCTAssertEqual(error.code, .internalError)
    XCTAssertTrue(error.diagnosticMessage.contains("Focused-window action failed"))
    XCTAssertTrue(error.diagnosticMessage.contains("invalid Accessibility window value"))
    XCTAssertTrue(error.diagnosticMessage.contains("setFrame"))
    XCTAssertTrue(
      logs.contains(
        level: .error,
        message: "Focused-window action failed: invalid Accessibility window value during setFrame"
      )
    )
  }

  func testWindowPlacementIncludesUnsupportedActionInDiagnosticMessage() async throws {
    let recorder = TestFocusedWindowController(
      placeError: FocusedWindowControlError.unsupportedAccessibilityOperation("raise")
    )
    let executor = ActionExecutor(
      configuration: .init(permissions: .init(ensureAccessibility: { true })),
      dependencies: makeActionExecutorDependencies(makeFocusedWindowController: { recorder })
    )

    let outcome = try await executor.execute(
      plan: ActionPlan(steps: [
        ActionStep(method: .windowing(.placeFocusedWindow(.init(placement: .fill))))
      ]))

    guard case .failure(let error) = outcome.finalResult else {
      return XCTFail("Expected failure")
    }
    XCTAssertEqual(error.code, .internalError)
    XCTAssertTrue(error.diagnosticMessage.contains("unsupported Accessibility window operation"))
    XCTAssertTrue(error.diagnosticMessage.contains("raise"))
  }

  func testWindowPlacementIncludesUnderlyingAccessibilityErrorInDiagnosticMessage() async throws {
    let recorder = TestFocusedWindowController(
      placeError: FocusedWindowControlError.accessibilityOperationFailed("cannotComplete")
    )
    let executor = ActionExecutor(
      configuration: .init(permissions: .init(ensureAccessibility: { true })),
      dependencies: makeActionExecutorDependencies(makeFocusedWindowController: { recorder })
    )

    let outcome = try await executor.execute(
      plan: ActionPlan(steps: [
        ActionStep(method: .windowing(.placeFocusedWindow(.init(placement: .fill))))
      ]))

    guard case .failure(let error) = outcome.finalResult else {
      return XCTFail("Expected failure")
    }
    XCTAssertEqual(error.code, .internalError)
    XCTAssertTrue(error.diagnosticMessage.contains("Accessibility window operation failed"))
    XCTAssertTrue(error.diagnosticMessage.contains("cannotComplete"))
  }

  func testWindowPlacementMapsUnexpectedErrorsToInternalError() async throws {
    let logs = LogRecorder()
    let recorder = TestFocusedWindowController(
      placeError: .unexpected("unexpected windowing error")
    )
    let executor = ActionExecutor(
      configuration: .init(
        permissions: .init(ensureAccessibility: { true }),
        log: { level, message in logs.record(level, message) }
      ),
      dependencies: makeActionExecutorDependencies(makeFocusedWindowController: { recorder })
    )

    let outcome = try await executor.execute(
      plan: ActionPlan(steps: [
        ActionStep(method: .windowing(.placeFocusedWindow(.init(placement: .fill))))
      ]))

    guard case .failure(let error) = outcome.finalResult else {
      return XCTFail("Expected failure")
    }
    XCTAssertEqual(error.code, .internalError)
    XCTAssertTrue(error.diagnosticMessage.contains("Focused-window action failed"))
    XCTAssertTrue(error.diagnosticMessage.contains("unexpected error"))
    XCTAssertTrue(error.diagnosticMessage.contains("unexpected windowing error"))
    XCTAssertTrue(
      logs.contains(
        level: .error,
        message: "Focused-window action failed: unexpected error: unexpected windowing error"
      )
    )
  }

  func testWindowPlacementMapsMissingScreenToNotFound() async throws {
    let logs = LogRecorder()
    let recorder = TestFocusedWindowController(
      placeError: .displayNotFound("orderedIndex(99)")
    )
    let executor = ActionExecutor(
      configuration: .init(
        permissions: .init(ensureAccessibility: { true }),
        log: { level, message in logs.record(level, message) }
      ),
      dependencies: makeActionExecutorDependencies(makeFocusedWindowController: { recorder })
    )

    let outcome = try await executor.execute(
      plan: ActionPlan(steps: [
        ActionStep(method: .windowing(.placeFocusedWindow(.init(placement: .fill))))
      ]))

    guard case .failure(let error) = outcome.finalResult else {
      return XCTFail("Expected failure")
    }
    XCTAssertEqual(error.code, .notFound)
    XCTAssertTrue(error.diagnosticMessage.contains("Window screen not found"))
    XCTAssertTrue(error.diagnosticMessage.contains("orderedIndex(99)"))
    XCTAssertTrue(
      logs.contains(level: .error, message: "Window screen not found: orderedIndex(99)")
    )
  }
}
