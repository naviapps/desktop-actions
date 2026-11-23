import Darwin
import Foundation
import XCTest

@testable import DesktopActionsMacOS

@MainActor
final class LiveScreenCaptureProcessRunnerTests: XCTestCase {
  func testArgumentsAndExitStatusArePreservedWithoutCapturingTheScreen() async throws {
    let fixture = try makeTemporaryExecutable(
      "[ \"$1\" = '-i' ] && [ \"$2\" = '-W' ] && exit 0\nexit 2")
    defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
    let runner = LiveScreenCaptureProcessRunner(executableURL: fixture)
    try await runner.run(arguments: ["-i", "-W"])
    do {
      try await runner.run(arguments: ["unexpected"])
      XCTFail("A nonzero exit must fail")
    } catch let failure as ScreenCaptureProcessFailure {
      XCTAssertEqual(failure.terminationStatus, 2)
    }
  }

  func testCancellationStopsAndReapsTheOwnedChildIgnoringTerminate() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let ready = directory.appendingPathComponent("ready")
    let fixture = try makeTemporaryExecutable(
      "trap '' TERM\necho $$ > '\(ready.path)'\nexec /bin/sleep 5", in: directory)
    let runner = LiveScreenCaptureProcessRunner(executableURL: fixture)
    let task = Task { try await runner.run(arguments: []) }
    defer { task.cancel() }
    var processID: Int32?
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while processID == nil, ContinuousClock.now < deadline {
      if let value = try? String(contentsOf: ready, encoding: .utf8) {
        processID = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines))
      }
      if processID == nil { try await Task.sleep(for: .milliseconds(10)) }
    }
    let pid = try XCTUnwrap(processID)
    let cancelledAt = ContinuousClock.now
    task.cancel()
    do {
      try await task.value
      XCTFail("Cancelled capture must not succeed")
    } catch is CancellationError {
      XCTAssertLessThan(cancelledAt.duration(to: .now), .seconds(3))
      XCTAssertEqual(Darwin.kill(pid, 0), -1)
      XCTAssertEqual(errno, ESRCH)
    }
  }

  func testCancellationBeforeLaunchDoesNotStartTheExecutable() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appendingPathComponent("started")
    let fixture = try makeTemporaryExecutable("touch '\(marker.path)'", in: directory)
    let runner = LiveScreenCaptureProcessRunner(executableURL: fixture)
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await runner.run(arguments: [])
    }
    do {
      try await task.value
      XCTFail("A cancelled capture must throw")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
  }
}
