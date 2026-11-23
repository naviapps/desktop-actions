import Darwin
import Foundation
import XCTest

@testable import DesktopActionsMacOS

final class LiveAppleScriptExecutorTests: XCTestCase {
  func testOwnedScriptRunsWithoutOpeningApplicationsOrPostingInput() async throws {
    let result = try await LiveAppleScriptExecutor().execute(source: "return 1 + 1")
    guard case .success = result else { return XCTFail("Owned script failed: \(result)") }
  }

  func testNativeErrorNumberSurvivesWithoutExposingScriptOrErrorText() async throws {
    let secret = "owned-sensitive-marker-" + UUID().uuidString
    let result = try await LiveAppleScriptExecutor().execute(
      source: "error \"\(secret)\" number -1743")
    guard case .failure(let failure) = result else { return XCTFail("Expected script failure") }
    XCTAssertEqual(failure.appleScriptErrorNumber, -1743)
    XCTAssertNil(failure.message)
  }

  func testCancellationStopsAndReapsOnlyTheOwnedScriptBeforeReturning() async throws {
    let marker = "navi-owned-script-" + UUID().uuidString
    let task = Task {
      try await LiveAppleScriptExecutor().execute(
        source: "set ownedMarker to \"\(marker)\"\ndelay 30")
    }
    defer { task.cancel() }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(3))
    var pid: pid_t?
    while clock.now < deadline {
      pid = try process(matching: marker)
      if pid != nil { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    guard let pid else {
      task.cancel()
      _ = await task.result
      return XCTFail("Owned script never started")
    }
    let start = clock.now
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {}
    XCTAssertLessThan(start.duration(to: clock.now), .seconds(2))
    let status = kill(pid, 0)
    let nativeError = errno
    XCTAssertEqual(status, -1)
    XCTAssertEqual(nativeError, ESRCH)
    XCTAssertNil(try process(matching: marker))
  }

  private func process(matching marker: String) throws -> pid_t? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-f", marker]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    if process.terminationStatus == 1 { return nil }
    guard process.terminationStatus == 0 else { throw CocoaError(.executableRuntimeMismatch) }
    let values = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
    guard values.count == 1, let pid = pid_t(values[0]) else {
      throw CocoaError(.executableRuntimeMismatch)
    }
    return pid
  }
}
