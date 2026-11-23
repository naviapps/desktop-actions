import DesktopActions
import DesktopActionsMacOS
import DesktopApplications
import Foundation
import XCTest

final class ActionExecutorWorkspaceCancellationTests: XCTestCase {
  func testCancellationAtEachApplicationLookupStopsDiscoveryAndLaunch() async {
    for (input, lookup, expected) in [
      ("Example", Lookup.name, [Lookup.name]),
      ("Example", .bundle, [.name, .bundle]),
      ("Example", .bundles, [.name, .bundle, .bundles]),
      ("com.example.app", .bundle, [.bundle]),
      ("com.example.app", .bundles, [.bundle, .bundles]),
      ("com.example.app", .name, [.bundle, .bundles, .name]),
    ] {
      for found in [false, true] {
        let started = expectation(description: "lookup \(input) \(lookup) \(found)")
        let workspace = SuspendedWorkspace(lookup: lookup, found: found, started: started)
        let executor = ActionExecutor(
          dependencies: makeActionExecutorDependencies(workspace: workspace))
        let task = Task { try await executor.execute(.launchApplication(input)) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await workspace.release()
        do {
          _ = try await task.value
          XCTFail("Cancelled discovery must throw")
        } catch {
          XCTAssertTrue(error is CancellationError)
        }
        let trace = await workspace.trace
        XCTAssertEqual(trace, expected.map(\.rawValue), "\(input), \(lookup), found=\(found)")
      }
    }
  }

  func testCancelledWindowOverviewDiscoveryDoesNotLaunchOrRunKeyboardFallback() async {
    let started = expectation(description: "Mission Control lookup")
    let workspace = SuspendedWorkspace(lookup: .bundle, found: false, started: started)
    let keys = TestKeyEventPoster()
    let executor = ActionExecutor(
      dependencies: makeActionExecutorDependencies(keyEventPoster: keys, workspace: workspace))
    let task = Task { try await executor.execute(.showWindowOverview) }
    await fulfillment(of: [started], timeout: 2)
    task.cancel()
    await workspace.release()
    do {
      _ = try await task.value
      XCTFail("Cancelled Mission Control must throw")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    let trace = await workspace.trace
    XCTAssertEqual(trace, [Lookup.bundle.rawValue])
    XCTAssertTrue(keys.postedEvents.isEmpty)
  }

  func testDeadlineDuringDiscoveryRetainsCapacityAndNeverLaunchesAfterRelease() async throws {
    let runner = try ActionRunner(maximumConcurrentExecutions: 1, timeout: .milliseconds(200))
    let started = expectation(description: "lookup before deadline")
    let acknowledged = expectation(description: "cancelled executor returned")
    let workspace = SuspendedWorkspace(lookup: .name, found: true, started: started)
    let executor = ActionExecutor(
      dependencies: makeActionExecutorDependencies(workspace: workspace))
    let task = Task {
      await runner.run(.launchApplication("Example")) { action async throws(CancellationError) in
        defer { acknowledged.fulfill() }
        return try await executor.execute(action)
      }
    }
    await fulfillment(of: [started], timeout: 2)
    let delivery = await task.value
    XCTAssertEqual(delivery, .timedOut)
    let occupied = await runner.run(.copy) { _ in
      XCTFail("Lookup has not acknowledged cancellation")
      return .init(attempts: [])
    }
    XCTAssertEqual(occupied, .busy)
    await workspace.release()
    await fulfillment(of: [acknowledged], timeout: 2)
    let trace = await workspace.trace
    XCTAssertEqual(trace, [Lookup.name.rawValue])
  }

  func testCancellationWhileOpeningDoesNotLogAnOrdinaryLaunchFailure() async {
    let logs = InvocationRecorder()
    let executor = ActionExecutor(
      configuration: .init(log: { _, _ in logs.record() }),
      dependencies: makeActionExecutorDependencies(workspace: CancellingLaunchWorkspace()))
    let task = Task { try await executor.execute(.launchApplication("Example")) }
    do {
      _ = try await task.value
      XCTFail("Cancelled launch must throw")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    XCTAssertEqual(logs.invocationCount, 0)
  }

  func testCancellationDuringStaleRegistrationDoesNotLookForOtherCopies() async {
    let alternateLookups = InvocationRecorder()
    let logs = InvocationRecorder()
    let executor = ActionExecutor(
      configuration: .init(log: { _, _ in logs.record() }),
      dependencies: makeActionExecutorDependencies(
        workspace: CancellingLaunchWorkspace(alternateLookups: alternateLookups)))
    let task = Task { try await executor.execute(.launchApplication("com.example.app")) }

    do {
      _ = try await task.value
      XCTFail("Cancelled launch must not try another copy")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    XCTAssertEqual(alternateLookups.invocationCount, 0)
    XCTAssertEqual(logs.invocationCount, 0)
  }

  func testCancellationWhileOpeningURLFolderOrShortcutDoesNotLogOpenFailure() async {
    for action: ActionRequest in [
      .openURL("https://example.com"),
      .openFolder(FileManager.default.temporaryDirectory.path),
      .runShortcut("Example"),
    ] {
      let logs = InvocationRecorder()
      let executor = ActionExecutor(
        configuration: .init(log: { _, _ in logs.record() }),
        dependencies: makeActionExecutorDependencies(workspace: CancellingLaunchWorkspace()))
      let task = Task { try await executor.execute(action) }
      do {
        _ = try await task.value
        XCTFail("Cancelled workspace open must throw")
      } catch {
        XCTAssertTrue(error is CancellationError)
      }
      XCTAssertEqual(logs.invocationCount, 0)
    }
  }
}

private enum Lookup: String, Sendable {
  case name, bundle, bundles
}

/// Discovery deliberately ignores cancellation until explicitly released.
private actor SuspendedWorkspace: WorkspaceControlling {
  let lookup: Lookup
  let found: Bool
  let started: XCTestExpectation
  private var continuation: CheckedContinuation<Void, Never>?
  private var released = false
  private(set) var trace: [String] = []

  init(lookup: Lookup, found: Bool, started: XCTestExpectation) {
    self.lookup = lookup
    self.found = found
    self.started = started
  }

  func release() {
    released = true
    continuation?.resume()
    continuation = nil
  }

  private func resolve(_ lookup: Lookup) async -> URL? {
    trace.append(lookup.rawValue)
    guard lookup == self.lookup else { return nil }
    started.fulfill()
    if !released {
      await withCheckedContinuation { continuation = $0 }
    }
    return found ? URL(fileURLWithPath: "/fixture/Example.app") : nil
  }

  func urlForApplication(named _: String) async -> URL? { await resolve(.name) }
  func urlForApplication(bundleIdentifier _: String) async -> URL? { await resolve(.bundle) }
  func urlsForApplications(bundleIdentifier _: String) async -> [URL] {
    if let url = await resolve(.bundles) { return [url] }
    return []
  }
  func open(_: URL) async -> Bool {
    trace.append("open")
    return true
  }
  func openApplication(
    at _: URL, activates _: Bool, expectedBundleIdentifier _: String?,
    allowsRunningApplicationSubstitution _: Bool
  ) async throws {
    trace.append("launch")
  }
}

private struct CancellingLaunchWorkspace: WorkspaceControlling {
  var alternateLookups: InvocationRecorder?

  func urlForApplication(named _: String) async -> URL? {
    URL(fileURLWithPath: "/fixture/Example.app")
  }
  func urlForApplication(bundleIdentifier _: String) async -> URL? {
    alternateLookups == nil ? nil : URL(fileURLWithPath: "/fixture/Example.app")
  }
  func urlsForApplications(bundleIdentifier _: String) async -> [URL] {
    alternateLookups?.record()
    return []
  }
  func open(_: URL) async -> Bool {
    withUnsafeCurrentTask { $0?.cancel() }
    return false
  }
  func openApplication(
    at _: URL, activates _: Bool, expectedBundleIdentifier: String?,
    allowsRunningApplicationSubstitution _: Bool
  ) async throws {
    withUnsafeCurrentTask { $0?.cancel() }
    if expectedBundleIdentifier != nil { throw ApplicationLaunchError.applicationBundleNotFound }
    throw TestApplicationOpenError()
  }
}
