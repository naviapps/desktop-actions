import AppKit
import Darwin
import DesktopActions
import Foundation
import XCTest

@testable import DesktopActionsMacOS

final class SystemEventsLaunchCoordinatorTests: XCTestCase {
  func testIndependentDefaultExecutorsShareLiveSystemEventsPreparation() async throws {
    let first = ActionExecutor()
    let second = ActionExecutor()
    let firstLauncher = await first.selectedLiveSystemEventsLauncher()
    let secondLauncher = await second.selectedLiveSystemEventsLauncher()

    XCTAssertTrue(
      try XCTUnwrap(firstLauncher) === XCTUnwrap(secondLauncher),
      "Independent default executors must use the same live System Events launcher"
    )
  }

  func testIndependentExecutorsShareColdLaunchWithoutSharingCancellationOrPermissionChecks()
    async throws
  {
    let launch = ManualSystemEventsLaunch()
    let probe = GatedSystemEventsLaunchProbe(launches: [launch])
    let coordinator = SystemEventsLaunchCoordinator(
      isRunning: { probe.isRunning },
      launch: { await probe.launch() },
      sleep: { _ in XCTFail("The released launch must be running") }
    )
    let launcher = TestCoordinatedSystemEventsLauncher(coordinator: coordinator)
    let checkedAutomation = expectation(description: "The surviving executor checked Automation")
    let cancelled = expectation(description: "The first executor returned before launch completed")
    let first = ActionExecutor(
      configuration: .init(
        permissions: .init(ensureAutomation: {
          XCTFail("A cancelled executor must not check Automation")
          return false
        })),
      dependencies: makeActionExecutorDependencies(systemEventsLauncher: launcher))
    let second = ActionExecutor(
      configuration: .init(
        permissions: .init(ensureAutomation: {
          checkedAutomation.fulfill()
          return true
        })),
      dependencies: makeActionExecutorDependencies(systemEventsLauncher: launcher))
    let firstTask = Task {
      defer { cancelled.fulfill() }
      do {
        _ = try await first.execute(.toggleAppearance)
        return false
      } catch {
        return true
      }
    }
    defer {
      firstTask.cancel()
      launch.release()
    }
    await fulfillment(of: [launch.started], timeout: 3)
    let secondTask = Task { try await second.execute(.toggleAppearance) }
    defer { secondTask.cancel() }

    let deadline = ContinuousClock.now + .seconds(3)
    while await coordinator.waitingCallerCount < 2, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    let waiters = await coordinator.waitingCallerCount
    guard waiters == 2 else { return XCTFail("Both executors must join before launch completes") }
    XCTAssertEqual(probe.launchCount, 1)

    firstTask.cancel()
    await fulfillment(of: [cancelled], timeout: 3)
    XCTAssertFalse(probe.isRunning)
    let survivingWaiters = await coordinator.waitingCallerCount
    XCTAssertEqual(survivingWaiters, 1)
    launch.release()
    let didCancel = await firstTask.value
    XCTAssertTrue(didCancel)
    let report = try await secondTask.value
    await fulfillment(of: [checkedAutomation], timeout: 3)
    XCTAssertEqual(report.finalResult, .success)
    XCTAssertEqual(probe.launchCount, 1)
  }

  @MainActor
  func testOwnedNaturalColdSystemEventsLaunchDoesNotActivateIt() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let lease = environment["NAVI_DESKTOP_ACTIONS_OWNED_SYSTEM_EVENTS"] else {
      throw XCTSkip("Owned native System Events probe not selected")
    }
    let selectionPath = try XCTUnwrap(environment["NAVI_CI_SOURCE_FILES"])
    let selection = URL(fileURLWithPath: selectionPath).resolvingSymlinksInPath()
    let source = selection.deletingLastPathComponent()
    let workspace = source.deletingLastPathComponent()
    guard selection.lastPathComponent == ".navi-ci-source-files.json",
      source.lastPathComponent == "source",
      workspace.deletingLastPathComponent().path
        == URL(fileURLWithPath: "/tmp")
        .resolvingSymlinksInPath().path
    else { return XCTFail("The native probe requires a captured lease workspace") }
    let marker = try JSONDecoder().decode(
      [String: String].self, from: Data(contentsOf: workspace.appendingPathComponent("lease.json")))
    guard UUID(uuidString: lease) != nil, workspace.lastPathComponent == "workspace-" + lease,
      marker == ["lease": lease], getuid() != 0, getuid() == geteuid()
    else { return XCTFail("The native probe requires its owned non-root lease") }

    let machine = Process()
    let output = Pipe()
    machine.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
    machine.arguments = ["-n", "hw.model"]
    machine.standardOutput = output
    try machine.run()
    machine.waitUntilExit()
    let model = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    guard machine.terminationStatus == 0, model.hasPrefix("VirtualMac") else {
      return XCTFail("The native probe requires a virtual Mac")
    }

    let bundle = SystemEventsLaunchCoordinator.bundleIdentifier
    func running() -> Bool {
      NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
        .contains { !$0.isTerminated }
    }
    if running() {
      print("DESKTOP_ACTIONS_NATIVE_SYSTEM_EVENTS_ALREADY_RUNNING")
      throw XCTSkip("System Events was already running; a cold start was not forced")
    }
    guard NSWorkspace.shared.frontmostApplication != nil else {
      print("DESKTOP_ACTIONS_NATIVE_SYSTEM_EVENTS_NO_FOREGROUND")
      throw XCTSkip("A graphical foreground application is unavailable")
    }
    let first = ActionExecutor()
    let second = ActionExecutor()
    let firstSelection = await first.selectedLiveSystemEventsLauncher()
    let secondSelection = await second.selectedLiveSystemEventsLauncher()
    let firstLauncher = try XCTUnwrap(firstSelection)
    let secondLauncher = try XCTUnwrap(secondSelection)
    // Exercise only launch preparation; no AppleScript, permission prompt or global input.
    let results = await withTaskGroup(of: Bool?.self, returning: [Bool].self) { group in
      group.addTask { await firstLauncher.ensureRunning() }
      group.addTask { await secondLauncher.ensureRunning() }
      group.addTask {
        try? await Task.sleep(for: .seconds(8))
        return nil
      }
      var results: [Bool] = []
      for await result in group {
        guard let result else { break }
        results.append(result)
        if results.count == 2 { break }
      }
      group.cancelAll()
      return results
    }
    XCTAssertEqual(results, [true, true])
    XCTAssertTrue(running())
    let foreground = try XCTUnwrap(NSWorkspace.shared.frontmostApplication)
    XCTAssertNotEqual(foreground.bundleIdentifier, bundle)
    print("DESKTOP_ACTIONS_NATIVE_SYSTEM_EVENTS_COLD_START_CHECKED")
  }

  func testEnsureRunningReturnsTrueWhenAlreadyRunning() async {
    let probe = SystemEventsLaunchProbe(isRunning: true)
    let coordinator = SystemEventsLaunchCoordinator(
      isRunning: { await probe.isRunning },
      launch: { await probe.launch() },
      sleep: { _ in }
    )

    let result = await coordinator.ensureRunning()

    XCTAssertTrue(result)
    let launchCount = await probe.currentLaunchCount()
    XCTAssertEqual(launchCount, 0)
  }

  func testEnsureRunningLaunchesAndWaitsUntilRunning() async {
    let probe = SystemEventsLaunchProbe(isRunning: false)
    let coordinator = SystemEventsLaunchCoordinator(
      isRunning: { await probe.isRunning },
      launch: { await probe.launch() },
      sleep: { _ in }
    )

    let result = await coordinator.ensureRunning()

    XCTAssertTrue(result)
    let launchCount = await probe.currentLaunchCount()
    XCTAssertEqual(launchCount, 1)
  }

  func testEnsureRunningPollsUntilSystemEventsBecomesRunning() async {
    let probe = PollingSystemEventsLaunchProbe(runningOnCheck: 3)
    let coordinator = SystemEventsLaunchCoordinator(
      isRunning: { await probe.checkIsRunning() },
      launch: { await probe.launch() },
      sleep: { _ in await probe.sleep() }
    )

    let result = await coordinator.ensureRunning()

    XCTAssertTrue(result)
    let launchCount = await probe.currentLaunchCount()
    XCTAssertEqual(launchCount, 1)
    let sleepCount = await probe.currentSleepCount()
    XCTAssertEqual(sleepCount, 1)
  }

  func testConcurrentEnsureRunningSharesLaunchTask() async {
    let probe = SuspendedSystemEventsLaunchProbe()
    let coordinator = SystemEventsLaunchCoordinator(
      isRunning: { await probe.checkIsRunning() },
      launch: { await probe.launch() },
      sleep: { _ in }
    )

    async let first = coordinator.ensureRunning()
    async let second = coordinator.ensureRunning()

    await probe.waitForLaunch()
    let inFlightLaunchCount = await probe.currentLaunchCount()
    XCTAssertEqual(inFlightLaunchCount, 1)

    await probe.finishLaunch()
    let results = await [first, second]

    XCTAssertEqual(results, [true, true])
    let finalLaunchCount = await probe.currentLaunchCount()
    XCTAssertEqual(finalLaunchCount, 1)
  }

  func testEnsureRunningReturnsFalseWhenLaunchDoesNotMakeSystemEventsRunning() async {
    let probe = SystemEventsLaunchProbe(isRunning: false, launchMakesRunning: false)
    let coordinator = SystemEventsLaunchCoordinator(
      isRunning: { await probe.isRunning },
      launch: { await probe.launch() },
      sleep: { _ in }
    )

    let result = await coordinator.ensureRunning()

    XCTAssertFalse(result)
    let launchCount = await probe.currentLaunchCount()
    XCTAssertEqual(launchCount, 1)
  }

  func testEnsureRunningRetriesAfterFailedLaunch() async {
    let probe = SystemEventsLaunchProbe(isRunning: false, launchResults: [false, true])
    let coordinator = SystemEventsLaunchCoordinator(
      isRunning: { await probe.isRunning },
      launch: { await probe.launch() },
      sleep: { _ in }
    )

    let first = await coordinator.ensureRunning()
    let second = await coordinator.ensureRunning()

    XCTAssertFalse(first)
    XCTAssertTrue(second)
    let launchCount = await probe.currentLaunchCount()
    XCTAssertEqual(launchCount, 2)
  }

  func testAlreadyCancelledRequestDoesNotQueryOrLaunch() async {
    let probe = SystemEventsLaunchProbe(isRunning: false)
    let coordinator = SystemEventsLaunchCoordinator(
      isRunning: { await probe.isRunning },
      launch: { await probe.launch() },
      sleep: { _ in }
    )
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return await coordinator.ensureRunning()
    }
    let result = await task.value
    XCTAssertFalse(result)
    let count = await probe.currentLaunchCount()
    XCTAssertEqual(count, 0)
  }

  func testCancellationStopsWaitingWithoutLaunchCallback() async {
    let probe = SuspendedSystemEventsLaunchProbe()
    let coordinator = SystemEventsLaunchCoordinator(
      isRunning: { await probe.checkIsRunning() },
      launch: { await probe.launch() },
      sleep: { _ in XCTFail("Abandoned launch must not poll") }
    )
    let returned = expectation(description: "Cancelled waiter returned before launch completed")
    let task = Task {
      let result = await coordinator.ensureRunning()
      returned.fulfill()
      return result
    }
    await probe.waitForLaunch()
    task.cancel()
    await fulfillment(of: [returned], timeout: 2)
    await probe.finishLaunch()
    let result = await task.value
    XCTAssertFalse(result)
  }

  func testCancellationDuringRunningQueryDoesNotLaunch() async {
    let query = SuspendedRunningQuery()
    let coordinator = SystemEventsLaunchCoordinator(
      isRunning: { await query.check() },
      launch: { XCTFail("Cancelled query must not launch") },
      sleep: { _ in XCTFail("Cancelled query must not poll") }
    )
    let returned = expectation(description: "Cancelled waiter returned before query completed")
    let task = Task {
      let result = await coordinator.ensureRunning()
      returned.fulfill()
      return result
    }
    await query.waitUntilStarted()
    task.cancel()
    await fulfillment(of: [returned], timeout: 2)
    await query.finish()
    let result = await task.value
    XCTAssertFalse(result)
  }

  func testCancellingOneWaiterPreservesSharedLaunchForSurvivor() async {
    let launch = ManualSystemEventsLaunch()
    let probe = GatedSystemEventsLaunchProbe(launches: [launch])
    let coordinator = SystemEventsLaunchCoordinator(
      isRunning: { probe.isRunning },
      launch: { await probe.launch() },
      sleep: { _ in XCTFail("The released launch must be running") }
    )
    let cancelled = SystemEventsWaiterResult()
    let survivor = SystemEventsWaiterResult()
    let first = await coordinator.startRegisteredWaiter(result: cancelled)
    let second = await coordinator.startRegisteredWaiter(result: survivor)
    defer {
      first.caller.cancel()
      second.caller.cancel()
      launch.release()
    }
    await fulfillment(of: [launch.started], timeout: 2)
    XCTAssertNotNil(first.worker)
    XCTAssertEqual(first.worker, second.worker)

    first.caller.cancel()
    await fulfillment(of: [cancelled.returned], timeout: 2)
    XCTAssertEqual(cancelled.value, false)
    XCTAssertNil(survivor.value)
    XCTAssertEqual(second.worker?.isCancelled, false)
    XCTAssertEqual(probe.launchCount, 1)

    launch.release()
    await fulfillment(of: [survivor.returned], timeout: 2)
    XCTAssertEqual(survivor.value, true)
    XCTAssertEqual(probe.launchCount, 1)
    await assertWorkerFinished(first.worker)
  }

  func testAbandonedGenerationCompletionCannotFinishNewWaiter() async {
    let oldLaunch = ManualSystemEventsLaunch()
    let newLaunch = ManualSystemEventsLaunch()
    let probe = GatedSystemEventsLaunchProbe(launches: [oldLaunch, newLaunch])
    let coordinator = SystemEventsLaunchCoordinator(
      isRunning: { probe.isRunning },
      launch: { await probe.launch() },
      sleep: { _ in XCTFail("The released launch must be running") }
    )
    let abandoned = SystemEventsWaiterResult()
    let first = await coordinator.startRegisteredWaiter(result: abandoned)
    defer {
      first.caller.cancel()
      oldLaunch.release()
      newLaunch.release()
    }
    await fulfillment(of: [oldLaunch.started], timeout: 2)

    first.caller.cancel()
    await fulfillment(of: [abandoned.returned], timeout: 2)
    XCTAssertEqual(abandoned.value, false)

    let survivor = SystemEventsWaiterResult()
    let second = await coordinator.startRegisteredWaiter(result: survivor)
    defer { second.caller.cancel() }
    await fulfillment(of: [newLaunch.started], timeout: 2)
    XCTAssertNotNil(first.worker)
    XCTAssertNotNil(second.worker)
    XCTAssertNotEqual(first.worker, second.worker)

    oldLaunch.release()
    // Await the worker, not just its injected launch callback: finish must have run.
    await assertWorkerFinished(first.worker)
    let activeWorker = await coordinator.launchTask
    XCTAssertEqual(activeWorker, second.worker)
    XCTAssertNil(survivor.value)
    XCTAssertEqual(second.worker?.isCancelled, false)

    newLaunch.release()
    await fulfillment(of: [survivor.returned], timeout: 2)
    XCTAssertEqual(survivor.value, true)
    XCTAssertEqual(probe.launchCount, 2)
    await assertWorkerFinished(second.worker)
  }

  private func assertWorkerFinished(
    _ worker: Task<Void, Never>?, file: StaticString = #filePath, line: UInt = #line
  ) async {
    guard let worker else {
      XCTFail("A registered waiter must have a launch worker", file: file, line: line)
      return
    }
    let finished = expectation(description: "Launch worker completed")
    let observer = Task {
      await worker.value
      finished.fulfill()
    }
    await fulfillment(of: [finished], timeout: 2)
    observer.cancel()
  }
}

extension ActionExecutor {
  fileprivate func selectedLiveSystemEventsLauncher() -> LiveSystemEventsLauncher? {
    dependencies.systemEventsLauncher as? LiveSystemEventsLauncher
  }
}

private struct TestCoordinatedSystemEventsLauncher: SystemEventsLaunching {
  let coordinator: SystemEventsLaunchCoordinator

  func ensureRunning() async -> Bool {
    await coordinator.ensureRunning()
  }
}

extension SystemEventsLaunchCoordinator {
  fileprivate func startRegisteredWaiter(result: SystemEventsWaiterResult) -> (
    caller: Task<Void, Never>, worker: Task<Void, Never>?
  ) {
    // Starting on this actor runs ensureRunning through registration to its first suspension.
    let caller = Task.immediate {
      result.complete(await self.ensureRunning())
    }
    return (caller, launchTask)
  }
}

private final class SystemEventsWaiterResult: @unchecked Sendable {
  let returned = XCTestExpectation(description: "System Events waiter returned")
  private let lock = NSLock()
  private var storedValue: Bool?

  var value: Bool? { lock.withLock { storedValue } }

  func complete(_ value: Bool) {
    lock.withLock { storedValue = value }
    returned.fulfill()
  }
}

private final class ManualSystemEventsLaunch: @unchecked Sendable {
  let started = XCTestExpectation(description: "Injected launch is suspended")
  private let lock = NSLock()
  private var released = false
  private var continuations: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    await withCheckedContinuation { continuation in
      let resumeImmediately = lock.withLock {
        if released { return true }
        continuations.append(continuation)
        return false
      }
      started.fulfill()
      if resumeImmediately { continuation.resume() }
    }
  }

  func release() {
    let pending = lock.withLock {
      released = true
      let pending = continuations
      continuations.removeAll()
      return pending
    }
    for continuation in pending { continuation.resume() }
  }
}

private final class GatedSystemEventsLaunchProbe: @unchecked Sendable {
  private let lock = NSLock()
  private let launches: [ManualSystemEventsLaunch]
  private var running = false
  private var count = 0

  init(launches: [ManualSystemEventsLaunch]) {
    self.launches = launches
  }

  var isRunning: Bool { lock.withLock { running } }
  var launchCount: Int { lock.withLock { count } }

  func launch() async {
    let gate = lock.withLock {
      let index = count
      count += 1
      return launches.indices.contains(index) ? launches[index] : nil
    }
    if let gate {
      await gate.wait()
    } else {
      XCTFail("Unexpected extra launch")
    }
    lock.withLock { running = true }
  }
}

private actor SuspendedRunningQuery {
  private var continuation: CheckedContinuation<Bool, Never>?
  private var started: CheckedContinuation<Void, Never>?
  private var finished = false

  func check() async -> Bool {
    if finished { return false }
    return await withCheckedContinuation {
      continuation = $0
      started?.resume()
      started = nil
    }
  }

  func waitUntilStarted() async {
    if continuation != nil { return }
    await withCheckedContinuation { started = $0 }
  }

  func finish() {
    finished = true
    continuation?.resume(returning: false)
    continuation = nil
  }
}

private actor SystemEventsLaunchProbe {
  private var running: Bool
  private var launchResults: [Bool]
  private(set) var launchCount = 0

  init(isRunning: Bool, launchMakesRunning: Bool = true) {
    running = isRunning
    self.launchResults = [launchMakesRunning]
  }

  init(isRunning: Bool, launchResults: [Bool]) {
    running = isRunning
    self.launchResults = launchResults
  }

  var isRunning: Bool {
    running
  }

  func launch() {
    launchCount += 1
    let launchMakesRunning =
      launchResults.isEmpty
      ? false
      : launchResults.removeFirst()
    if launchMakesRunning {
      running = true
    }
  }

  func currentLaunchCount() -> Int {
    launchCount
  }
}

private actor PollingSystemEventsLaunchProbe {
  private let runningOnCheck: Int
  private var runningCheckCount = 0
  private var launchCount = 0
  private var sleepCount = 0

  init(runningOnCheck: Int) {
    self.runningOnCheck = runningOnCheck
  }

  func checkIsRunning() -> Bool {
    runningCheckCount += 1
    return runningCheckCount >= runningOnCheck
  }

  func launch() {
    launchCount += 1
  }

  func sleep() {
    sleepCount += 1
  }

  func currentLaunchCount() -> Int {
    launchCount
  }

  func currentSleepCount() -> Int {
    sleepCount
  }
}

private actor SuspendedSystemEventsLaunchProbe {
  private var running = false
  private var launchCount = 0
  private var launchContinuation: CheckedContinuation<Void, Never>?
  private var launchWaiters: [CheckedContinuation<Void, Never>] = []

  func checkIsRunning() -> Bool {
    running
  }

  func launch() async {
    launchCount += 1
    for waiter in launchWaiters { waiter.resume() }
    launchWaiters.removeAll()
    await withCheckedContinuation { continuation in
      launchContinuation = continuation
    }
    running = true
  }

  func waitForLaunch() async {
    if launchCount > 0 {
      return
    }

    await withCheckedContinuation { continuation in
      launchWaiters.append(continuation)
    }
  }

  func finishLaunch() {
    launchContinuation?.resume()
    launchContinuation = nil
  }

  func currentLaunchCount() -> Int {
    launchCount
  }

}
