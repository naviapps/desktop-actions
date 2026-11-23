import AppKit
import DesktopActionsMacOS
import Foundation
import XCTest

final class SystemKeyEventPosterTests: XCTestCase {
  func testDefaultFactoryEncodesSystemDefinedDownAndUpWithoutKeyboardEvents() {
    let events = Recorder()
    let poster = SystemKeyEventPoster(postEvent: { events.append($0) })
    XCTAssertTrue(poster.post(16))
    XCTAssertEqual(events.types, [14, 14])
    XCTAssertEqual(events.subtypes, [8, 8])
    XCTAssertEqual(events.data, [(16 << 16) | 0x0a00, (16 << 16) | 0x0b00])
  }

  func testFailedUpAllocationPostsNeitherEdge() {
    let events = Recorder()
    let poster = SystemKeyEventPoster(
      makeEvent: { _, down in down ? CGEvent(source: nil) : nil },
      postEvent: { events.append($0) })
    XCTAssertFalse(poster.post(16))
    XCTAssertTrue(events.types.isEmpty)
  }

  private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedTypes: [UInt32] = []
    private var storedSubtypes: [Int16] = []
    private var storedData: [Int] = []
    var types: [UInt32] { lock.withLock { storedTypes } }
    var subtypes: [Int16] { lock.withLock { storedSubtypes } }
    var data: [Int] { lock.withLock { storedData } }
    func append(_ value: CGEvent) {
      lock.withLock {
        storedTypes.append(value.type.rawValue)
        if let event = NSEvent(cgEvent: value) {
          storedSubtypes.append(event.subtype.rawValue)
          storedData.append(event.data1)
        }
      }
    }
  }
}
