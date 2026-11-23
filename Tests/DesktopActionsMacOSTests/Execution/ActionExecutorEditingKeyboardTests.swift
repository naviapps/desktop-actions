import ApplicationServices
import DesktopActions
import DesktopActionsMacOS
import Foundation
import XCTest

@MainActor
final class EditingKeyResolverTests: XCTestCase {
  func testResolvesUniqueKeysIndependentlyForUndoAndRedo() throws {
    let snapshots = EditingLayoutSnapshots([editingLayout()])

    let undo = try XCTUnwrap(snapshots.resolver.resolve(.z, shift: false))
    let redo = try XCTUnwrap(snapshots.resolver.resolve(.z, shift: true))

    XCTAssertEqual(undo.virtualKey, 13)
    XCTAssertEqual(redo.virtualKey, 14)
    XCTAssertTrue(snapshots.resolver.isCurrent(undo))
    XCTAssertTrue(snapshots.resolver.isCurrent(redo))
  }

  func testRejectsMissingAndDuplicateLayoutTranslations() {
    let snapshots = EditingLayoutSnapshots([editingLayout(undoKeys: [13, 17], redoKeys: [])])

    XCTAssertNil(snapshots.resolver.resolve(.z, shift: false))
    XCTAssertNil(snapshots.resolver.resolve(.z, shift: true))
    XCTAssertNil(EditingLayoutSnapshots([nil]).resolver.resolve(.z, shift: false))
  }

  func testCapturedMatchIsInvalidWhenLayoutIdentityBytesOrTranslationChange() throws {
    let changed: [(String, EditingKeyResolver.Layout?)] = [
      ("selected source", editingLayout(selectedSourceIdentifier: "fixture.input.other")),
      ("effective layout", editingLayout(effectiveLayoutIdentifier: "fixture.layout.other")),
      ("keyboard type", editingLayout(keyboardType: 41)),
      ("layout bytes", editingLayout(data: Data([1, 3]))),
      ("key translation", editingLayout(undoKeys: [17])),
      ("unavailable layout", nil),
    ]
    for (description, layout) in changed {
      let snapshots = EditingLayoutSnapshots([editingLayout(), layout])
      let resolver = snapshots.resolver
      let match = try XCTUnwrap(resolver.resolve(.z, shift: false), description)

      XCTAssertFalse(resolver.isCurrent(match), description)
    }
  }
}

@MainActor
final class ActionExecutorEditingKeyboardTests: XCTestCase {
  func testTypedEditingUsesResolvedKeysWhileExplicitShortcutsStayPhysical() async throws {
    let snapshots = EditingLayoutSnapshots([editingLayout()])
    let poster = TestKeyEventPoster()
    let executor = makeExecutor(poster: poster, snapshots: snapshots)
    let actions: [(request: ActionRequest, modifiers: ActionModifiers)] = [
      (.undo, [.command]), (.redo, [.command, .shift]),
    ]

    for (request, modifiers) in actions {
      let plan = ActionPreflight.plan(for: request)
      XCTAssertEqual(
        plan.steps.map(\.method), [.keyEvent(.init(virtualKeyCode: 6, modifiers: modifiers))])

      let report = try await executor.execute(request)
      XCTAssertEqual(report.finalResult, .success)
      XCTAssertEqual(report.attempts.map(\.requiredPermissions), [[.accessibility]])
      XCTAssertFalse(report.didAttemptFallback)
    }
    XCTAssertEqual(poster.postedEvents.map(\.virtualKey), [13, 14])
    XCTAssertEqual(poster.postedEvents.map(\.flags), [[.maskCommand], [.maskCommand, .maskShift]])

    let editingReads = snapshots.reads
    XCTAssertGreaterThan(editingReads, 0)
    let explicit = try await executor.execute(.keyboardShortcut("cmd z"))
    let rawMethod = ActionMethod.keyEvent(.init(virtualKeyCode: 6, modifiers: [.command]))
    let raw = try await executor.execute(plan: .init(steps: [.init(method: rawMethod)]))
    XCTAssertEqual(explicit.finalResult, .success)
    XCTAssertEqual(raw.finalResult, .success)
    XCTAssertEqual(snapshots.reads, editingReads)
    XCTAssertEqual(poster.postedEvents.map(\.virtualKey), [13, 14, 6, 6])
    XCTAssertEqual(
      poster.postedEvents.map(\.flags),
      [[.maskCommand], [.maskCommand, .maskShift], [.maskCommand], [.maskCommand]])
    XCTAssertTrue(poster.postedSystemKeys.isEmpty)
  }

  func testUnavailableOrAmbiguousEditingLayoutFailsWithoutPosting() async throws {
    let layouts: [EditingKeyResolver.Layout?] = [nil, editingLayout(undoKeys: [13, 17])]
    for layout in layouts {
      let snapshots = EditingLayoutSnapshots([layout])
      let poster = TestKeyEventPoster()
      let report = try await makeExecutor(poster: poster, snapshots: snapshots).execute(.undo)

      assertFailure(report, code: .unsupportedAction)
      XCTAssertTrue(poster.postedEvents.isEmpty)
      XCTAssertTrue(poster.postedSystemKeys.isEmpty)
    }
  }

  func testTypedClipboardActionsUseLogicalKeysWhileStoredShortcutsStayPhysical() async throws {
    // Dvorak control: the canonical C/V/X positions translate to J/K/Q.
    let snapshots = EditingLayoutSnapshots([
      editingLayout(editingKeys: [
        8: 0x6A, 9: 0x6B, 7: 0x71,
        34: 0x43, 47: 0x76, 11: 0x78,
      ])
    ])
    let poster = TestKeyEventPoster()
    let executor = makeExecutor(poster: poster, snapshots: snapshots)
    let guardCalls = InvocationRecorder()

    let requests: [ActionRequest] = [.copy, .paste, .cut]
    for request in requests {
      let report = try await executor.execute(
        request,
        beforeStep: {
          guardCalls.record()
          return true
        })
      XCTAssertEqual(report.finalResult, .success)
      XCTAssertEqual(report.attempts.map(\.requiredPermissions), [[.accessibility]])
      XCTAssertFalse(report.didAttemptFallback)
    }
    XCTAssertEqual(poster.postedEvents.map(\.virtualKey), [34, 47, 11])
    XCTAssertEqual(guardCalls.invocationCount, requests.count * 2)

    let layoutReads = snapshots.reads
    XCTAssertGreaterThan(layoutReads, 0)
    let explicit = try await executor.execute(.keyboardShortcut("cmd x"))
    let rawMethod = ActionMethod.keyEvent(.init(virtualKeyCode: 7, modifiers: [.command]))
    let raw = try await executor.execute(plan: .init(steps: [.init(method: rawMethod)]))
    XCTAssertEqual(explicit.finalResult, .success)
    XCTAssertEqual(raw.finalResult, .success)
    XCTAssertEqual(snapshots.reads, layoutReads)
    XCTAssertEqual(poster.postedEvents.map(\.virtualKey), [34, 47, 11, 7, 7])
    XCTAssertTrue(poster.postedEvents.allSatisfy { $0.flags == [.maskCommand] })
    XCTAssertTrue(poster.postedSystemKeys.isEmpty)
  }

  func testUnavailableAmbiguousOrChangedCutLayoutNeverPosts() async throws {
    let layouts: [[EditingKeyResolver.Layout?]] = [
      [nil],
      [editingLayout(editingKeys: [7: 0x71])],
      [editingLayout(editingKeys: [11: 0x78, 17: 0x58])],
      [
        editingLayout(editingKeys: [11: 0x78]),
        // Same source and layout identity, but the admitted key no longer translates to X.
        editingLayout(editingKeys: [11: 0x7A, 17: 0x78]),
      ],
    ]
    for layout in layouts {
      let snapshots = EditingLayoutSnapshots(layout)
      let poster = TestKeyEventPoster()
      let report = try await makeExecutor(poster: poster, snapshots: snapshots).execute(.cut)

      assertFailure(report, code: .unsupportedAction)
      XCTAssertGreaterThanOrEqual(snapshots.reads, layout.count)
      XCTAssertTrue(poster.postedEvents.isEmpty)
      XCTAssertTrue(poster.postedSystemKeys.isEmpty)
    }
  }

  func testTypedSelectAllAndFindUseLogicalKeysWithoutChangingPhysicalShortcuts() async throws {
    for testCase in Self.layoutAwareShortcutCases {
      let keys = [testCase.physical: testCase.alternateLetter, testCase.logical: testCase.letter]
      let snapshots = EditingLayoutSnapshots([editingLayout(editingKeys: keys)])
      let poster = TestKeyEventPoster()
      let executor = makeExecutor(poster: poster, snapshots: snapshots)
      let guardCalls = InvocationRecorder()

      let semantic = try await executor.execute(
        testCase.request,
        beforeStep: {
          guardCalls.record()
          return true
        })
      XCTAssertEqual(semantic.finalResult, .success, testCase.raw)
      XCTAssertEqual(semantic.attempts.map(\.requiredPermissions), [[.accessibility]])
      XCTAssertFalse(semantic.didAttemptFallback)
      XCTAssertEqual(guardCalls.invocationCount, 2)
      XCTAssertEqual(poster.postedEvents.map(\.virtualKey), [testCase.logical], testCase.raw)

      let layoutReads = snapshots.reads
      XCTAssertGreaterThan(layoutReads, 0)
      let raw = try await executor.execute(.keyboardShortcut(testCase.raw))
      XCTAssertEqual(raw.finalResult, .success, testCase.raw)
      XCTAssertEqual(snapshots.reads, layoutReads)
      XCTAssertEqual(
        poster.postedEvents.map(\.virtualKey), [testCase.logical, testCase.physical], testCase.raw)
      XCTAssertTrue(poster.postedEvents.allSatisfy { $0.flags == [.maskCommand] })
    }
  }

  func testSelectAllAndFindDoNotPostPhysicalKeysWhenLogicalLetterIsUnavailable() async throws {
    for testCase in Self.layoutAwareShortcutCases {
      let missing = [testCase.physical: testCase.alternateLetter]
      var ambiguous = missing
      ambiguous[testCase.logical] = testCase.letter
      ambiguous[15] = testCase.letter - 32
      for keys in [missing, ambiguous] {
        let snapshots = EditingLayoutSnapshots([editingLayout(editingKeys: keys)])
        let poster = TestKeyEventPoster()
        let report = try await makeExecutor(poster: poster, snapshots: snapshots).execute(
          testCase.request)

        assertFailure(report, code: .unsupportedAction)
        XCTAssertTrue(poster.postedEvents.isEmpty, testCase.raw)
        XCTAssertTrue(poster.postedSystemKeys.isEmpty, testCase.raw)
      }
    }
  }

  private static let layoutAwareShortcutCases:
    [(
      request: ActionRequest, raw: String, physical: UInt16, alternateLetter: UInt16,
      logical: UInt16, letter: UInt16
    )] = [
      // French AZERTY: the physical A position emits Q; logical A is at 12.
      (.selectAll, "cmd+a", 0, 0x71, 12, 0x61),
      // Dvorak: the physical F position emits U; logical F is at 16.
      (.findInApp, "cmd+f", 3, 0x75, 16, 0x66),
    ]

  func testLayoutChangeAfterResolutionPreventsGuardedEmission() async throws {
    let changedLayouts = [
      editingLayout(effectiveLayoutIdentifier: "fixture.layout.other"),
      editingLayout(data: Data([1, 3])),
    ]
    for changed in changedLayouts {
      let snapshots = EditingLayoutSnapshots([editingLayout(), changed])
      let poster = TestKeyEventPoster()
      let report = try await makeExecutor(poster: poster, snapshots: snapshots).execute(.undo)

      assertFailure(report, code: .unsupportedAction)
      XCTAssertGreaterThanOrEqual(snapshots.reads, 2)
      XCTAssertTrue(poster.postedEvents.isEmpty)
      XCTAssertTrue(poster.postedSystemKeys.isEmpty)
    }
  }

  func testCurrentEditingLayoutWithPosterFailureKeepsInternalError() async throws {
    let snapshots = EditingLayoutSnapshots([editingLayout()])
    let poster = TestKeyEventPoster(result: false)
    let report = try await makeExecutor(poster: poster, snapshots: snapshots).execute(.redo)

    assertFailure(report, code: .internalError)
    XCTAssertEqual(poster.postedEvents.map(\.virtualKey), [14])
    XCTAssertEqual(poster.postedEvents.map(\.flags), [[.maskCommand, .maskShift]])
  }

  func testDeniedEditingPermissionDoesNotResolveOrPost() async throws {
    let snapshots = EditingLayoutSnapshots([editingLayout()])
    let poster = TestKeyEventPoster()
    let executor = makeExecutor(poster: poster, snapshots: snapshots, accessibility: false)
    let guardCalls = InvocationRecorder()

    let report = try await executor.execute(
      .redo,
      beforeStep: {
        guardCalls.record()
        return true
      })

    XCTAssertEqual(report.finalResult, .failure(.permissionDenied(.accessibility)))
    XCTAssertEqual(guardCalls.invocationCount, 2)
    XCTAssertEqual(snapshots.reads, 0)
    XCTAssertTrue(poster.postedEvents.isEmpty)
    XCTAssertTrue(poster.postedSystemKeys.isEmpty)
  }

  func testRejectedOrCancelledBeforeStepDoesNotResolveOrPost() async {
    for cancelWhileChecking in [false, true] {
      let snapshots = EditingLayoutSnapshots([editingLayout()])
      let poster = TestKeyEventPoster()
      let guardCalls = InvocationRecorder()
      let executor = makeExecutor(poster: poster, snapshots: snapshots)
      let task = Task {
        try await executor.execute(
          .undo,
          beforeStep: {
            guardCalls.record()
            if cancelWhileChecking { withUnsafeCurrentTask { $0?.cancel() } }
            return cancelWhileChecking
          })
      }

      do {
        _ = try await task.value
        XCTFail("A rejected or cancelled editing step must throw")
      } catch {
        XCTAssertTrue(error is CancellationError)
      }
      XCTAssertEqual(guardCalls.invocationCount, 1)
      XCTAssertEqual(snapshots.reads, 0)
      XCTAssertTrue(poster.postedEvents.isEmpty)
      XCTAssertTrue(poster.postedSystemKeys.isEmpty)
    }
  }

  private func makeExecutor(
    poster: TestKeyEventPoster, snapshots: EditingLayoutSnapshots, accessibility: Bool = true
  ) -> ActionExecutor {
    ActionExecutor(
      configuration: .init(permissions: .init(ensureAccessibility: { accessibility })),
      dependencies: makeActionExecutorDependencies(
        keyEventPoster: poster, editingKeyResolver: snapshots.resolver))
  }

  private func assertFailure(
    _ report: ActionExecutionReport, code: ActionErrorCode,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    guard case .failure(let error) = report.finalResult else {
      return XCTFail("Expected an editing failure", file: file, line: line)
    }
    XCTAssertEqual(error.code, code, file: file, line: line)
    XCTAssertEqual(report.attempts.count, 1, file: file, line: line)
    XCTAssertFalse(report.didAttemptFallback, file: file, line: line)
  }
}

@MainActor
private final class EditingLayoutSnapshots {
  private let layouts: [EditingKeyResolver.Layout?]
  private(set) var reads = 0

  init(_ layouts: [EditingKeyResolver.Layout?]) {
    precondition(!layouts.isEmpty)
    self.layouts = layouts
  }

  var resolver: EditingKeyResolver {
    EditingKeyResolver(snapshot: {
      let layout = self.layouts[min(self.reads, self.layouts.count - 1)]
      self.reads += 1
      return layout
    })
  }
}

@MainActor
private func editingLayout(
  selectedSourceIdentifier: String = "fixture.input",
  effectiveLayoutIdentifier: String = "fixture.layout",
  keyboardType: UInt32 = 40, data: Data = Data([1, 2]), undoKeys: Set<UInt16> = [13],
  redoKeys: Set<UInt16> = [14], editingKeys: [UInt16: UInt16] = [:]
) -> EditingKeyResolver.Layout {
  EditingKeyResolver.Layout(
    selectedSourceIdentifier: selectedSourceIdentifier,
    effectiveLayoutIdentifier: effectiveLayoutIdentifier, keyboardType: keyboardType, data: data,
    translate: { key, shift in
      if shift { return redoKeys.contains(key) ? 0x005A : nil }
      if undoKeys.contains(key) { return 0x007A }
      return editingKeys[key]
    })
}
