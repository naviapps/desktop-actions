import DesktopActions
import DesktopApplications
import XCTest

@testable import DesktopActionsMacOS

final class ActionExecutorLaunchApplicationTests: XCTestCase {
  func testLaunchApplicationPreservesNonWhitespaceUnicodeFromRust() async throws {
    let name = "\u{200B}Example"
    let workspace = TestWorkspace(
      applicationURLForName: URL(fileURLWithPath: "/fixture/Example.app"))
    let executor = ActionExecutor(
      dependencies: makeActionExecutorDependencies(workspace: workspace))
    let outcome = try await executor.execute(.launchApplication(" \(name) \n"))
    let snapshot = await workspace.applicationLaunchSnapshot
    XCTAssertEqual(outcome.finalResult, .success)
    XCTAssertEqual(snapshot.resolvedApplicationNames, [name])
  }

  func testLaunchApplicationReturnsInvalidInputForEmptyValue() async throws {
    let workspace = TestWorkspace()
    let executor = ActionExecutor(
      configuration: .init(),
      dependencies: makeActionExecutorDependencies(workspace: workspace)
    )

    let outcome = try await executor.execute(.launchApplication(" "))
    guard case .failure(let error) = outcome.finalResult else {
      return XCTFail("Expected failure, got: \(outcome.finalResult)")
    }
    XCTAssertEqual(error.code, .invalidInput)
    XCTAssertFalse(error.diagnosticMessage.isEmpty)
    let snapshot = await workspace.applicationLaunchSnapshot
    XCTAssertNil(snapshot.openedApplicationURL)
    XCTAssertTrue(snapshot.resolvedBundleIdentifiers.isEmpty)
    XCTAssertTrue(snapshot.resolvedApplicationNames.isEmpty)
  }

  func testLaunchApplicationReturnsOpenFailedWhenBundleLaunchThrows() async throws {
    let tempURL = try makeTemporaryDirectory()
    let logs = LogRecorder()
    defer {
      try? FileManager.default.removeItem(at: tempURL)
    }

    let executor = ActionExecutor(
      configuration: .init(log: { level, message in logs.record(level, message) }),
      dependencies: makeActionExecutorDependencies(
        workspace: TestWorkspace(
          applicationURLForBundleIdentifier: tempURL,
          openApplicationError: TestApplicationOpenError()
        )
      )
    )

    let outcome = try await executor.execute(.launchApplication("com.example.app"))
    guard case .failure(let error) = outcome.finalResult else {
      return XCTFail("Expected failure, got: \(outcome.finalResult)")
    }
    XCTAssertEqual(error.code, .openFailed)
    XCTAssertTrue(error.diagnosticMessage.contains("bundle identifier"))
    XCTAssertTrue(
      logs.contains(level: .error, message: "Failed to launch application by bundle identifier")
    )
  }

  func testLaunchApplicationReturnsOpenFailedWhenPathLaunchThrows() async throws {
    let tempURL = try makeTemporaryApplicationBundleDirectory()
    let logs = LogRecorder()
    defer {
      try? FileManager.default.removeItem(at: tempURL)
    }

    let executor = ActionExecutor(
      configuration: .init(log: { level, message in logs.record(level, message) }),
      dependencies: makeActionExecutorDependencies(
        workspace: TestWorkspace(
          applicationURLForBundleIdentifier: nil,
          applicationURLsForBundleIdentifier: [],
          openApplicationError: TestApplicationOpenError()
        )
      )
    )

    let outcome = try await executor.execute(.launchApplication(tempURL.path))
    guard case .failure(let error) = outcome.finalResult else {
      return XCTFail("Expected failure, got: \(outcome.finalResult)")
    }
    XCTAssertEqual(error.code, .openFailed)
    XCTAssertTrue(error.diagnosticMessage.contains("Failed to launch application at path"))
    XCTAssertTrue(logs.contains(level: .error, message: "Failed to launch application at path"))
  }

  func testLaunchApplicationUsesExistingPathBeforeBundleIdentifierLookup() async throws {
    let tempURL = try makeTemporaryApplicationBundleDirectory()
    defer {
      try? FileManager.default.removeItem(at: tempURL)
    }
    let workspace = TestWorkspace(
      applicationURLForBundleIdentifier: URL(fileURLWithPath: "/Applications/Other.app"))
    let executor = ActionExecutor(
      configuration: .init(),
      dependencies: makeActionExecutorDependencies(workspace: workspace)
    )

    let outcome = try await executor.execute(.launchApplication(tempURL.path))
    let snapshot = await workspace.applicationLaunchSnapshot

    XCTAssertEqual(outcome.finalResult, .success)
    XCTAssertEqual(snapshot.openedApplicationURL?.standardized.path, tempURL.standardized.path)
    XCTAssertEqual(snapshot.openedApplicationActivates, true)
    XCTAssertEqual(snapshot.openedApplicationAllowsSubstitution, false)
    XCTAssertEqual(snapshot.resolvedBundleIdentifiers, [])
    XCTAssertEqual(snapshot.resolvedApplicationNames, [])
  }

  func testLiveExplicitPathLaunchDoesNotSubstituteAnotherRunningCopy() async throws {
    let bundle = try makeTemporaryApplicationBundleDirectory()
    defer { try? FileManager.default.removeItem(at: bundle) }
    let opened = InvocationRecorder()
    let workspace = LiveWorkspace(requestOpening: { url, configuration in
      XCTAssertEqual(url.standardizedFileURL, bundle.standardizedFileURL)
      XCTAssertTrue(configuration.activates)
      XCTAssertFalse(configuration.allowsRunningApplicationSubstitution)
      XCTAssertFalse(configuration.createsNewApplicationInstance)
      opened.record()
    })
    let executor = ActionExecutor(
      dependencies: makeActionExecutorDependencies(workspace: workspace))

    let outcome = try await executor.execute(.launchApplication(bundle.path))

    XCTAssertEqual(outcome.finalResult, .success)
    XCTAssertEqual(opened.invocationCount, 1)
  }

  func testLaunchApplicationExpandsTildeApplicationPath() async throws {
    let appName = ".desktop-actions-\(UUID().uuidString).app"
    let appURL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(appName)
    try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: appURL)
    }
    let workspace = TestWorkspace(
      applicationURLForBundleIdentifier: URL(fileURLWithPath: "/Applications/Other.app"))
    let executor = ActionExecutor(
      configuration: .init(),
      dependencies: makeActionExecutorDependencies(workspace: workspace)
    )

    let outcome = try await executor.execute(.launchApplication("~/\(appName)"))
    let snapshot = await workspace.applicationLaunchSnapshot

    XCTAssertEqual(outcome.finalResult, .success)
    XCTAssertEqual(snapshot.openedApplicationURL?.standardized.path, appURL.standardized.path)
    XCTAssertEqual(snapshot.openedApplicationActivates, true)
    XCTAssertEqual(snapshot.openedApplicationAllowsSubstitution, false)
    XCTAssertEqual(snapshot.resolvedBundleIdentifiers, [])
    XCTAssertEqual(snapshot.resolvedApplicationNames, [])
  }

  func testLaunchApplicationRejectsExistingNonApplicationPath() async throws {
    let tempURL = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: tempURL)
    }
    let workspace = TestWorkspace(
      applicationURLForBundleIdentifier: URL(fileURLWithPath: "/Applications/Other.app"))
    let executor = ActionExecutor(
      configuration: .init(),
      dependencies: makeActionExecutorDependencies(workspace: workspace)
    )

    let outcome = try await executor.execute(.launchApplication(tempURL.path))
    let snapshot = await workspace.applicationLaunchSnapshot

    guard case .failure(let error) = outcome.finalResult else {
      return XCTFail("Expected failure, got: \(outcome.finalResult)")
    }
    XCTAssertEqual(error.code, .invalidInput)
    XCTAssertTrue(error.diagnosticMessage.contains(".app bundle"))
    XCTAssertNil(snapshot.openedApplicationURL)
    XCTAssertNil(snapshot.openedApplicationActivates)
    XCTAssertEqual(snapshot.resolvedBundleIdentifiers, [])
    XCTAssertEqual(snapshot.resolvedApplicationNames, [])
  }

  func testLaunchApplicationReturnsNotFoundForMissingApplicationPath() async throws {
    let missingURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("app")
    let workspace = TestWorkspace(
      applicationURLForBundleIdentifier: URL(fileURLWithPath: "/Applications/Other.app"),
      applicationURLForName: URL(fileURLWithPath: "/Applications/Other.app")
    )
    let executor = ActionExecutor(
      configuration: .init(),
      dependencies: makeActionExecutorDependencies(workspace: workspace)
    )

    let outcome = try await executor.execute(.launchApplication(missingURL.path))
    let snapshot = await workspace.applicationLaunchSnapshot

    guard case .failure(let error) = outcome.finalResult else {
      return XCTFail("Expected failure, got: \(outcome.finalResult)")
    }
    XCTAssertEqual(error.code, .notFound)
    XCTAssertTrue(error.diagnosticMessage.contains("Application path does not exist"))
    XCTAssertNil(snapshot.openedApplicationURL)
    XCTAssertNil(snapshot.openedApplicationActivates)
    XCTAssertEqual(snapshot.resolvedBundleIdentifiers, [])
    XCTAssertEqual(snapshot.resolvedApplicationNames, [])
  }

  func testLaunchApplicationResolvesApplicationNameBeforeBundleIdentifierLookup() async throws {
    let tempURL = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: tempURL)
    }
    let workspace = TestWorkspace(
      applicationURLForBundleIdentifier: nil,
      applicationURLsForBundleIdentifier: [],
      applicationURLForName: tempURL
    )
    let executor = ActionExecutor(
      configuration: .init(),
      dependencies: makeActionExecutorDependencies(workspace: workspace)
    )

    let outcome = try await executor.execute(.launchApplication("Safari"))
    let snapshot = await workspace.applicationLaunchSnapshot

    XCTAssertEqual(outcome.finalResult, .success)
    XCTAssertEqual(snapshot.openedApplicationURL?.standardized.path, tempURL.standardized.path)
    XCTAssertEqual(snapshot.openedApplicationActivates, true)
    XCTAssertEqual(snapshot.openedApplicationAllowsSubstitution, true)
    XCTAssertEqual(snapshot.resolvedBundleIdentifiers, [])
    XCTAssertEqual(snapshot.resolvedApplicationNames, ["Safari"])
  }

  func testLaunchApplicationFallsBackToBundleIdentifierWhenNameLookupMisses() async throws {
    let tempURL = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: tempURL)
    }
    let workspace = TestWorkspace(
      applicationURLForBundleIdentifier: tempURL,
      applicationURLForName: nil
    )
    let executor = ActionExecutor(
      configuration: .init(),
      dependencies: makeActionExecutorDependencies(workspace: workspace)
    )

    let outcome = try await executor.execute(.launchApplication("Safari"))
    let snapshot = await workspace.applicationLaunchSnapshot

    XCTAssertEqual(outcome.finalResult, .success)
    XCTAssertEqual(snapshot.openedApplicationURL?.standardized.path, tempURL.standardized.path)
    XCTAssertEqual(snapshot.openedApplicationActivates, true)
    XCTAssertEqual(snapshot.resolvedApplicationNames, ["Safari"])
    XCTAssertEqual(snapshot.resolvedBundleIdentifiers, ["Safari"])
  }

  func testLaunchApplicationResolvesBundleIdentifierBeforeApplicationName() async throws {
    let tempURL = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: tempURL)
    }
    let workspace = TestWorkspace(
      applicationURLForBundleIdentifier: tempURL,
      applicationURLForName: URL(fileURLWithPath: "/Applications/Other.app")
    )
    let executor = ActionExecutor(
      configuration: .init(),
      dependencies: makeActionExecutorDependencies(workspace: workspace)
    )

    let outcome = try await executor.execute(.launchApplication("com.example.app"))
    let snapshot = await workspace.applicationLaunchSnapshot

    XCTAssertEqual(outcome.finalResult, .success)
    XCTAssertEqual(snapshot.openedApplicationURL?.standardized.path, tempURL.standardized.path)
    XCTAssertEqual(snapshot.openedApplicationActivates, true)
    XCTAssertEqual(snapshot.openedApplicationAllowsSubstitution, true)
    XCTAssertEqual(snapshot.resolvedBundleIdentifiers, ["com.example.app"])
    XCTAssertEqual(snapshot.resolvedApplicationNames, [])
  }

  func testLaunchApplicationUsesFirstBundleIdentifierCandidateWhenPrimaryLookupMisses()
    async throws
  {
    let tempURL = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: tempURL)
    }
    let workspace = TestWorkspace(
      applicationURLForBundleIdentifier: nil,
      applicationURLsForBundleIdentifier: [tempURL],
      applicationURLForName: URL(fileURLWithPath: "/Applications/Other.app")
    )
    let executor = ActionExecutor(
      configuration: .init(),
      dependencies: makeActionExecutorDependencies(workspace: workspace)
    )

    let outcome = try await executor.execute(.launchApplication("com.example.app"))
    let snapshot = await workspace.applicationLaunchSnapshot

    XCTAssertEqual(outcome.finalResult, .success)
    XCTAssertEqual(snapshot.openedApplicationURL?.standardized.path, tempURL.standardized.path)
    XCTAssertEqual(snapshot.openedApplicationActivates, true)
    XCTAssertEqual(snapshot.resolvedBundleIdentifiers, ["com.example.app", "com.example.app"])
    XCTAssertEqual(snapshot.resolvedApplicationNames, [])
  }

  func testLaunchApplicationSkipsStaleAndDuplicateRegisteredCopies() async throws {
    let identifier = "com.example.app"
    let missing = URL(fileURLWithPath: "/fixture/Missing.app")
    let invalid = URL(fileURLWithPath: "/fixture/Invalid.app")
    let available = URL(fileURLWithPath: "/fixture/Available.app")
    let unneeded = URL(fileURLWithPath: "/fixture/Unneeded.app")
    let workspace = TestWorkspace(
      applicationURLForBundleIdentifier: missing,
      applicationURLsForBundleIdentifier: [missing, invalid, invalid, available, unneeded],
      registeredOpenErrors: [
        missing: .applicationBundleNotFound, invalid: .invalidApplicationBundleURL,
      ]
    )
    let executor = ActionExecutor(
      dependencies: makeActionExecutorDependencies(workspace: workspace))

    let outcome = try await executor.execute(.launchApplication(identifier))

    let attempts = await workspace.attemptedApplicationOpenings
    XCTAssertEqual(outcome.finalResult, .success)
    XCTAssertEqual(attempts.map(\.url), [missing, invalid, available])
    XCTAssertEqual(attempts.map(\.expectedIdentifier), [identifier, identifier, identifier])
  }

  func testLaunchApplicationDoesNotTryOtherCopiesAfterAnOpeningRequestIsRejected() async throws {
    let rejected = URL(fileURLWithPath: "/fixture/Rejected.app")
    let workspace = TestWorkspace(
      applicationURLForBundleIdentifier: rejected,
      applicationURLsForBundleIdentifier: [URL(fileURLWithPath: "/fixture/Another.app")],
      registeredOpenErrors: [rejected: .requestRejected]
    )
    let executor = ActionExecutor(
      dependencies: makeActionExecutorDependencies(workspace: workspace))

    let outcome = try await executor.execute(.launchApplication("com.example.app"))

    guard case .failure(let error) = outcome.finalResult else {
      return XCTFail("Expected failure")
    }
    let snapshot = await workspace.applicationLaunchSnapshot
    let attempts = await workspace.attemptedApplicationOpenings
    XCTAssertEqual(error.code, .openFailed)
    XCTAssertEqual(snapshot.resolvedBundleIdentifiers, ["com.example.app"])
    XCTAssertEqual(attempts.map(\.url), [rejected])
  }

  func testLaunchApplicationDoesNotTryNameWhenAllRegisteredCopiesAreStale() async throws {
    let missing = URL(fileURLWithPath: "/fixture/Missing.app")
    let workspace = TestWorkspace(
      applicationURLsForBundleIdentifier: [missing],
      applicationURLForName: URL(fileURLWithPath: "/fixture/Unrelated.app"),
      registeredOpenErrors: [missing: .applicationBundleNotFound]
    )
    let executor = ActionExecutor(
      dependencies: makeActionExecutorDependencies(workspace: workspace))

    let outcome = try await executor.execute(.launchApplication("com.example.app"))

    guard case .failure(let error) = outcome.finalResult else {
      return XCTFail("Expected failure")
    }
    let snapshot = await workspace.applicationLaunchSnapshot
    XCTAssertEqual(error.code, .openFailed)
    XCTAssertTrue(snapshot.resolvedApplicationNames.isEmpty)
  }

  func testLiveRegisteredLaunchRejectsAChangedBundleIdentifierBeforeDispatch() async throws {
    let bundle = try makeTemporaryApplicationBundleDirectory()
    defer { try? FileManager.default.removeItem(at: bundle) }
    let contents = bundle.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: false)
    let info = contents.appendingPathComponent("Info.plist")
    let opened = InvocationRecorder()
    let workspace = LiveWorkspace(requestOpening: { _, configuration in
      XCTAssertTrue(configuration.allowsRunningApplicationSubstitution)
      XCTAssertFalse(configuration.createsNewApplicationInstance)
      opened.record()
    })

    let expected = "com.example.app"
    try writeIdentifier(expected, to: info)
    try await workspace.openApplication(
      at: bundle, activates: true, expectedBundleIdentifier: expected,
      allowsRunningApplicationSubstitution: true)
    XCTAssertEqual(opened.invocationCount, 1)

    try writeIdentifier("com.example.replacement", to: info)
    do {
      try await workspace.openApplication(
        at: bundle, activates: true, expectedBundleIdentifier: expected,
        allowsRunningApplicationSubstitution: true)
      XCTFail("A stale registration must not dispatch a different application")
    } catch let error as ApplicationLaunchError {
      XCTAssertEqual(error, .invalidApplicationBundleURL)
    }
    XCTAssertEqual(opened.invocationCount, 1)
  }

  func testLiveRegisteredLaunchFollowsMatchingRegularInfoPlistLink() async throws {
    let bundle = try makeTemporaryApplicationBundleDirectory()
    defer { try? FileManager.default.removeItem(at: bundle) }
    let contents = bundle.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: false)
    let metadata = contents.appendingPathComponent("AppInfo.plist")
    let identifier = "com.example.app"
    try writeIdentifier(identifier, to: metadata)
    try FileManager.default.createSymbolicLink(
      atPath: contents.appendingPathComponent("Info.plist").path,
      withDestinationPath: metadata.lastPathComponent)
    let opened = InvocationRecorder()
    let workspace = LiveWorkspace(requestOpening: { _, _ in opened.record() })

    try await workspace.openApplication(
      at: bundle, activates: true, expectedBundleIdentifier: identifier,
      allowsRunningApplicationSubstitution: true)

    XCTAssertEqual(opened.invocationCount, 1)
  }

  private func writeIdentifier(_ value: String, to url: URL) throws {
    let data = try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIdentifier": value], format: .binary, options: 0)
    try data.write(to: url, options: .atomic)
  }

  func testLaunchApplicationFallsBackToApplicationNameWhenBundleIdentifierLookupMisses()
    async throws
  {
    let tempURL = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: tempURL)
    }
    let workspace = TestWorkspace(
      applicationURLForBundleIdentifier: nil,
      applicationURLsForBundleIdentifier: [],
      applicationURLForName: tempURL
    )
    let executor = ActionExecutor(
      configuration: .init(),
      dependencies: makeActionExecutorDependencies(workspace: workspace)
    )

    let outcome = try await executor.execute(.launchApplication("Preview.app"))
    let snapshot = await workspace.applicationLaunchSnapshot

    XCTAssertEqual(outcome.finalResult, .success)
    XCTAssertEqual(snapshot.openedApplicationURL?.standardized.path, tempURL.standardized.path)
    XCTAssertEqual(snapshot.openedApplicationActivates, true)
    XCTAssertEqual(snapshot.resolvedBundleIdentifiers, ["Preview.app", "Preview.app"])
    XCTAssertEqual(snapshot.resolvedApplicationNames, ["Preview.app"])
  }

  func testLaunchApplicationReturnsNotFoundWhenNoCandidateFound() async throws {
    let executor = ActionExecutor(
      configuration: .init(),
      dependencies: makeActionExecutorDependencies(
        workspace: TestWorkspace(
          applicationURLForBundleIdentifier: nil,
          applicationURLsForBundleIdentifier: []
        )
      )
    )

    let outcome = try await executor.execute(.launchApplication("com.example.missing"))
    guard case .failure(let error) = outcome.finalResult else {
      return XCTFail("Expected failure, got: \(outcome.finalResult)")
    }
    XCTAssertEqual(error.code, .notFound)
    XCTAssertTrue(error.diagnosticMessage.contains("Unable to resolve application"))
  }

  func testLaunchApplicationReturnsOpenFailedWhenNameLaunchThrows() async throws {
    let tempURL = try makeTemporaryDirectory()
    let logs = LogRecorder()
    defer {
      try? FileManager.default.removeItem(at: tempURL)
    }

    let executor = ActionExecutor(
      configuration: .init(log: { level, message in logs.record(level, message) }),
      dependencies: makeActionExecutorDependencies(
        workspace: TestWorkspace(
          applicationURLForName: tempURL,
          openApplicationError: TestApplicationOpenError()
        )
      )
    )

    let outcome = try await executor.execute(.launchApplication("Safari"))
    guard case .failure(let error) = outcome.finalResult else {
      return XCTFail("Expected failure, got: \(outcome.finalResult)")
    }
    XCTAssertEqual(error.code, .openFailed)
    XCTAssertTrue(error.diagnosticMessage.contains("Failed to launch application by name"))
    XCTAssertTrue(logs.contains(level: .error, message: "Failed to launch application by name"))
  }
}
