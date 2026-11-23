import DesktopActions
import WindowManagement
import XCTest

enum ActionTestFixtures {
  static func assertExecutionCapacityReleased(
    _ runner: ActionRunner, report: ActionExecutionReport,
    file: StaticString = #filePath, line: UInt = #line
  ) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    repeat {
      let outcome = await runner.run(.copy) { _ in report }
      if case .busy = outcome {
        await Task.yield()
        continue
      }
      XCTAssertEqual(outcome, .completed(report), file: file, line: line)
      return
    } while clock.now < deadline
    XCTFail("Worker did not acknowledge completion", file: file, line: line)
  }

  static var actionKindCases: [(action: ActionRequest, kind: ActionKind)] {
    let cases =
      inputFreeActionKindCases
      + inputActionCases.map { (action: $0.action, kind: $0.kind) }
    let actionsByKind = Dictionary(uniqueKeysWithValues: cases.map { ($0.kind, $0.action) })

    return ActionKind.allCases.compactMap { kind in
      actionsByKind[kind].map { action in (action: action, kind: kind) }
    }
  }

  static var inputActionCases: [(kind: ActionKind, input: ActionInput, action: ActionRequest)] {
    let placement = WindowPlacementRequest(
      placement: .grid(columns: 2, rows: 1, column: 0, row: 0, columnSpan: 1, rowSpan: 1))
    let move = WindowMoveRequest(direction: .next)

    return [
      (.keyboardShortcut, .string("cmd+c"), .keyboardShortcut("cmd+c")),
      (.openURL, .string("https://example.com"), .openURL("https://example.com")),
      (.launchApplication, .string("com.example.App"), .launchApplication("com.example.App")),
      (.runShortcut, .string("Daily"), .runShortcut("Daily")),
      (.openFolder, .string("/Applications"), .openFolder("/Applications")),
      (.windowPlacement, .windowPlacement(placement), .windowPlacement(placement)),
      (.windowMove, .windowMove(move), .windowMove(move)),
    ]
  }

  private static var inputFreeActionKindCases: [(action: ActionRequest, kind: ActionKind)] {
    [
      (.copy, .copy),
      (.paste, .paste),
      (.cut, .cut),
      (.undo, .undo),
      (.redo, .redo),
      (.selectAll, .selectAll),
      (.findInApp, .findInApp),
      (.hideFrontmostApplication, .hideFrontmostApplication),
      (.quitFrontmostApplication, .quitFrontmostApplication),
      (.volumeUp, .volumeUp),
      (.volumeDown, .volumeDown),
      (.toggleAudioMute, .toggleAudioMute),
      (.mediaPlayPause, .mediaPlayPause),
      (.mediaNext, .mediaNext),
      (.mediaPrevious, .mediaPrevious),
      (.showWindowOverview, .showWindowOverview),
      (.showDesktop, .showDesktop),
      (.lockScreen, .lockScreen),
      (.sleepSystem, .sleepSystem),
      (.switchToNextVirtualDesktop, .switchToNextVirtualDesktop),
      (.switchToPreviousVirtualDesktop, .switchToPreviousVirtualDesktop),
      (.missionControlAppExpose, .missionControlAppExpose),
      (.brightnessUp, .brightnessUp),
      (.brightnessDown, .brightnessDown),
      (.toggleAppearance, .toggleAppearance),
      (.showNotificationCenter, .showNotificationCenter),
      (.captureScreenFull, .captureScreenFull),
      (.captureScreenSelection, .captureScreenSelection),
      (.captureScreenWindow, .captureScreenWindow),
      (.minimizeFocusedWindow, .minimizeFocusedWindow),
      (.toggleFocusedWindowFullScreen, .toggleFocusedWindowFullScreen),
      (.closeForegroundWindow, .closeForegroundWindow),
    ]
  }
}
