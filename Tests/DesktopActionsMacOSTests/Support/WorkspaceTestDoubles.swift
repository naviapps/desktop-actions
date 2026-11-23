import DesktopActionsMacOS
import DesktopApplications
import Foundation

struct TestApplicationOpenError: Error {}

actor TestWorkspace: WorkspaceControlling {
  let openURLResult: Bool
  let applicationURLForBundleIdentifier: URL?
  let applicationURLsForBundleIdentifier: [URL]
  let applicationURLForName: URL?
  let openApplicationError: TestApplicationOpenError?
  let registeredOpenErrors: [URL: ApplicationLaunchError]
  private(set) var lastOpenedURL: URL?
  private(set) var resolvedBundleIdentifiers: [String] = []
  private(set) var resolvedApplicationNames: [String] = []
  private(set) var openedApplicationURL: URL?
  private(set) var openedApplicationActivates: Bool?
  private var openedApplicationAllowsSubstitution: Bool?
  private(set) var attemptedApplicationOpenings: [(url: URL, expectedIdentifier: String?)] = []

  init(
    openURLResult: Bool = true,
    applicationURLForBundleIdentifier: URL? = nil,
    applicationURLsForBundleIdentifier: [URL] = [],
    applicationURLForName: URL? = nil,
    openApplicationError: TestApplicationOpenError? = nil,
    registeredOpenErrors: [URL: ApplicationLaunchError] = [:]
  ) {
    self.openURLResult = openURLResult
    self.applicationURLForBundleIdentifier = applicationURLForBundleIdentifier
    self.applicationURLsForBundleIdentifier = applicationURLsForBundleIdentifier
    self.applicationURLForName = applicationURLForName
    self.openApplicationError = openApplicationError
    self.registeredOpenErrors = registeredOpenErrors
  }

  func open(_ url: URL) async -> Bool {
    lastOpenedURL = url
    return openURLResult
  }

  func urlForApplication(bundleIdentifier: String) async -> URL? {
    resolvedBundleIdentifiers.append(bundleIdentifier)
    return applicationURLForBundleIdentifier
  }

  func urlsForApplications(bundleIdentifier: String) async -> [URL] {
    resolvedBundleIdentifiers.append(bundleIdentifier)
    return applicationURLsForBundleIdentifier
  }

  func urlForApplication(named name: String) async -> URL? {
    resolvedApplicationNames.append(name)
    return applicationURLForName
  }

  func openApplication(
    at url: URL, activates: Bool, expectedBundleIdentifier: String?,
    allowsRunningApplicationSubstitution: Bool
  ) async throws {
    attemptedApplicationOpenings.append((url, expectedBundleIdentifier))
    openedApplicationURL = url
    openedApplicationActivates = activates
    openedApplicationAllowsSubstitution = allowsRunningApplicationSubstitution
    if expectedBundleIdentifier != nil, let error = registeredOpenErrors[url] {
      throw error
    }
    if let openApplicationError {
      throw openApplicationError
    }
  }

  var applicationLaunchSnapshot:
    (
      openedApplicationURL: URL?,
      openedApplicationActivates: Bool?,
      openedApplicationAllowsSubstitution: Bool?,
      resolvedBundleIdentifiers: [String],
      resolvedApplicationNames: [String]
    )
  {
    (
      openedApplicationURL,
      openedApplicationActivates,
      openedApplicationAllowsSubstitution,
      resolvedBundleIdentifiers,
      resolvedApplicationNames
    )
  }
}
