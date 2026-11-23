import ApplicationServices
import DesktopActionsMacOS
import Dispatch
import Foundation
import XCTest

final class KeyEventPairConcurrencyTests: XCTestCase {
  func testKeyboardAndSystemKeyPairsDoNotInterleave() {
    let fixture = Fixture()
    let first = fixture.startHeldKeyboardPair()
    defer { fixture.releaseKeyboard.signal() }
    guard fixture.waitForKeyboardDown() else { return }

    let second = DispatchGroup()
    DispatchQueue.global().async(group: second) {
      XCTAssertTrue(fixture.systemPoster.post(16))
    }
    XCTAssertEqual(fixture.systemPairPrepared.wait(timeout: .now() + 5), .success)
    // The competing worker has built both edges while the first down is held.
    XCTAssertEqual(fixture.systemPosted.wait(timeout: .now() + .milliseconds(250)), .timedOut)
    fixture.releaseKeyboard.signal()
    XCTAssertEqual(first.wait(timeout: .now() + 5), .success)
    XCTAssertEqual(second.wait(timeout: .now() + 5), .success)
    XCTAssertEqual(fixture.posts, ["keyboard down", "keyboard up", "system down", "system up"])
  }

  func testCancelledWaitingSystemKeyPostsNeitherEdge() async {
    let fixture = Fixture()
    let first = fixture.startHeldKeyboardPair()
    defer { fixture.releaseKeyboard.signal() }
    guard fixture.waitForKeyboardDown() else { return }

    let second = Task.detached { fixture.systemPoster.post(16) }
    XCTAssertEqual(fixture.systemPairPrepared.wait(timeout: .now() + 5), .success)
    second.cancel()
    fixture.releaseKeyboard.signal()
    let posted = await second.value
    XCTAssertFalse(posted)
    XCTAssertEqual(first.wait(timeout: .now() + 5), .success)
    XCTAssertEqual(fixture.posts, ["keyboard down", "keyboard up"])
  }

  func testCancellationAfterDownStillPostsUp() async {
    let fixture = Fixture()
    let task = Task.detached {
      KeyStrokeEventPoster(postKeyEvent: { event in
        fixture.record(event.type == .keyDown ? "down" : "up")
        if event.type == .keyDown {
          withUnsafeCurrentTask { $0?.cancel() }
        }
      }).postKeyStroke(virtualKey: 12, flags: [])
    }
    let posted = await task.value
    XCTAssertTrue(posted)
    XCTAssertEqual(fixture.posts, ["down", "up"])
  }

  private final class Fixture: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    private let keyboardDownPosted = DispatchSemaphore(value: 0)
    let releaseKeyboard = DispatchSemaphore(value: 0)
    let systemPairPrepared = DispatchSemaphore(value: 0)
    let systemPosted = DispatchSemaphore(value: 0)

    var posts: [String] { lock.withLock { events } }

    func record(_ value: String) {
      lock.withLock { events.append(value) }
    }

    func waitForKeyboardDown() -> Bool {
      let result = keyboardDownPosted.wait(timeout: .now() + 5)
      XCTAssertEqual(result, .success)
      return result == .success
    }

    func startHeldKeyboardPair() -> DispatchGroup {
      let group = DispatchGroup()
      DispatchQueue.global().async(group: group) {
        let poster = KeyStrokeEventPoster(postKeyEvent: { event in
          if event.type == .keyDown {
            self.record("keyboard down")
            self.keyboardDownPosted.signal()
            XCTAssertEqual(self.releaseKeyboard.wait(timeout: .now() + 5), .success)
          } else {
            self.record("keyboard up")
          }
        })
        XCTAssertTrue(poster.postKeyStroke(virtualKey: 12, flags: []))
      }
      return group
    }

    var systemPoster: SystemKeyEventPoster {
      SystemKeyEventPoster(
        makeEvent: { _, down in
          let event = CGEvent(keyboardEventSource: nil, virtualKey: 12, keyDown: down)
          if !down { self.systemPairPrepared.signal() }
          return event
        },
        postEvent: { event in
          self.record(event.type == .keyDown ? "system down" : "system up")
          self.systemPosted.signal()
        })
    }
  }
}
