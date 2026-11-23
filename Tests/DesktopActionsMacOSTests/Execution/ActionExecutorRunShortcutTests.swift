import DesktopActions
import DesktopActionsMacOS
import XCTest

final class ActionExecutorRunShortcutTests: XCTestCase {
  func testRunShortcutPreservesNonWhitespaceUnicodeFromRust() async throws {
    let name = "\u{200B}Example"
    let workspace = TestWorkspace()
    let executor = ActionExecutor(
      dependencies: makeActionExecutorDependencies(workspace: workspace))
    let outcome = try await executor.execute(.runShortcut(" \(name) \n"))
    let opened = await workspace.lastOpenedURL
    let url = try XCTUnwrap(opened)
    XCTAssertEqual(outcome.finalResult, .success)
    XCTAssertEqual(
      URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
      [URLQueryItem(name: "name", value: name)])
  }

  func testRunShortcutBuildsShortcutsURL() async throws {
    let workspace = TestWorkspace()
    let dependencies = makeActionExecutorDependencies(workspace: workspace)
    let executor = ActionExecutor(configuration: .init(), dependencies: dependencies)

    let outcome = try await executor.execute(.runShortcut("My Shortcut"))
    XCTAssertEqual(outcome.finalResult, ActionResult.success)

    guard let lastURL = await workspace.lastOpenedURL else {
      return XCTFail("Expected URL to be opened")
    }
    XCTAssertEqual(lastURL.scheme, "shortcuts")
    XCTAssertEqual(lastURL.host, "run-shortcut")
    XCTAssertEqual(
      URLComponents(url: lastURL, resolvingAgainstBaseURL: false)?.queryItems,
      [
        URLQueryItem(name: "name", value: "My Shortcut")
      ])
  }

  func testRunShortcutTrimsShortcutNameBeforeOpening() async throws {
    let workspace = TestWorkspace()
    let dependencies = makeActionExecutorDependencies(workspace: workspace)
    let executor = ActionExecutor(configuration: .init(), dependencies: dependencies)

    let outcome = try await executor.execute(.runShortcut("  My Shortcut  "))
    XCTAssertEqual(outcome.finalResult, ActionResult.success)

    guard let lastURL = await workspace.lastOpenedURL else {
      return XCTFail("Expected URL to be opened")
    }
    XCTAssertEqual(
      URLComponents(url: lastURL, resolvingAgainstBaseURL: false)?.queryItems,
      [
        URLQueryItem(name: "name", value: "My Shortcut")
      ])
  }

  func testRunShortcutReturnsInvalidInputForEmptyName() async throws {
    let workspace = TestWorkspace()
    let executor = ActionExecutor(
      configuration: .init(),
      dependencies: makeActionExecutorDependencies(workspace: workspace)
    )

    let outcome = try await executor.execute(.runShortcut(" "))
    let lastOpenedURL = await workspace.lastOpenedURL

    guard case .failure(let error) = outcome.finalResult else {
      return XCTFail("Expected failure, got: \(outcome.finalResult)")
    }
    XCTAssertEqual(error.code, .invalidInput)
    XCTAssertFalse(error.diagnosticMessage.isEmpty)
    XCTAssertNil(lastOpenedURL)
  }

  func testRunShortcutReturnsOpenFailedWhenWorkspaceFails() async throws {
    let logs = LogRecorder()
    let workspace = TestWorkspace(openURLResult: false)
    let executor = ActionExecutor(
      configuration: .init(log: { level, message in logs.record(level, message) }),
      dependencies: makeActionExecutorDependencies(workspace: workspace)
    )

    let outcome = try await executor.execute(.runShortcut("My Shortcut"))
    let lastOpenedURL = await workspace.lastOpenedURL

    guard case .failure(let error) = outcome.finalResult else {
      return XCTFail("Expected failure, got: \(outcome.finalResult)")
    }
    XCTAssertEqual(error.code, .openFailed)
    XCTAssertEqual(lastOpenedURL?.scheme, "shortcuts")
    XCTAssertEqual(lastOpenedURL?.host, "run-shortcut")
    XCTAssertTrue(error.diagnosticMessage.contains("Failed to run shortcut"))
    XCTAssertTrue(logs.contains(level: .error, message: "Failed to run shortcut"))
  }
}
