import DesktopActions
import DesktopApplications
import Foundation

extension ActionExecutor {
  func executeOpenFolder(_ path: String) async throws(CancellationError) -> ActionResult {
    try checkCancellation()
    let expanded = (path as NSString).expandingTildeInPath
    let url = URL(fileURLWithPath: expanded)

    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      return notFoundResult("Folder does not exist")
    }

    try checkCancellation()
    let ok = await dependencies.workspace.open(url)
    try checkCancellation()
    guard ok else {
      return openFailedResult("Failed to open folder")
    }
    return .success
  }

  func executeOpenURL(_ urlString: String) async throws(CancellationError) -> ActionResult {
    try checkCancellation()
    guard let url = URL(string: urlString) else {
      return internalErrorResult("The native URL bridge rejected a validated URL")
    }

    let ok = await dependencies.workspace.open(url)
    try checkCancellation()
    guard ok else {
      return openFailedResult("Failed to open URL")
    }
    return .success
  }

  func executeLaunchApplication(_ applicationIdentifierOrPath: String)
    async throws(CancellationError) -> ActionResult
  {
    try checkCancellation()
    if let pathResult = applicationPathResult(for: applicationIdentifierOrPath) {
      switch pathResult {
      case .valid(let appURL):
        return try await openApplication(
          at: appURL, allowsRunningApplicationSubstitution: false,
          failureMessage: "Failed to launch application at path")
      case .missing:
        return notFoundResult("Application path does not exist")
      case .invalid(let message):
        return invalidInputResult(message)
      }
    }

    if applicationIdentifierOrPath.contains(".") {
      if let result = try await launchRegisteredApplication(applicationIdentifierOrPath) {
        return result
      }
      if let result = try await launchApplication(named: applicationIdentifierOrPath) {
        return result
      }
    } else {
      if let result = try await launchApplication(named: applicationIdentifierOrPath) {
        return result
      }
      if let result = try await launchRegisteredApplication(applicationIdentifierOrPath) {
        return result
      }
    }

    return notFoundResult("Unable to resolve application")
  }

  func executeRunShortcut(_ shortcutName: String) async throws(CancellationError) -> ActionResult {
    try checkCancellation()
    var components = URLComponents()
    components.scheme = "shortcuts"
    components.host = "run-shortcut"
    components.queryItems = [
      URLQueryItem(name: "name", value: shortcutName)
    ]

    guard let url = components.url else {
      return internalErrorResult("Failed to build shortcut URL")
    }

    let ok = await dependencies.workspace.open(url)
    try checkCancellation()
    guard ok else {
      return openFailedResult("Failed to run shortcut")
    }
    return .success
  }

  private func applicationPathResult(for path: String) -> ApplicationPathResult? {
    guard pathLooksLikeFilePath(path) else { return nil }

    let expanded = (path as NSString).expandingTildeInPath
    let url = URL(fileURLWithPath: expanded)
    guard FileManager.default.fileExists(atPath: url.path) else { return .missing }

    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      isDirectory.boolValue,
      url.pathExtension.lowercased() == "app"
    else {
      return .invalid("Application path must point to an .app bundle")
    }
    return .valid(url)
  }

  private func pathLooksLikeFilePath(_ value: String) -> Bool {
    value.hasPrefix("~") || value.hasPrefix("/") || value.contains("/")
  }

  private func launchRegisteredApplication(_ bundleIdentifier: String)
    async throws(CancellationError) -> ActionResult?
  {
    try checkCancellation()
    let preferred = await dependencies.workspace.urlForApplication(
      bundleIdentifier: bundleIdentifier
    )
    try checkCancellation()
    var tried: Set<URL> = []
    if let preferred {
      tried.insert(preferred.standardized)
      if let result = try await openRegisteredApplication(at: preferred, matching: bundleIdentifier)
      {
        return result
      }
    }

    let registrations = await dependencies.workspace.urlsForApplications(
      bundleIdentifier: bundleIdentifier
    )
    try checkCancellation()
    for candidate in registrations where tried.insert(candidate.standardized).inserted {
      if let result = try await openRegisteredApplication(at: candidate, matching: bundleIdentifier)
      {
        return result
      }
    }
    return tried.isEmpty ? nil : openFailedResult(Self.registeredLaunchFailure)
  }

  private static let registeredLaunchFailure = "Failed to launch application by bundle identifier"

  private func openRegisteredApplication(at url: URL, matching bundleIdentifier: String)
    async throws(CancellationError) -> ActionResult?
  {
    switch try await attemptOpeningApplication(
      at: url, expectedBundleIdentifier: bundleIdentifier,
      allowsRunningApplicationSubstitution: true)
    {
    case .opened: return .success
    case .staleRegistration: return nil
    case .failed: return openFailedResult(Self.registeredLaunchFailure)
    }
  }

  private func launchApplication(named name: String)
    async throws(CancellationError) -> ActionResult?
  {
    try checkCancellation()
    let url = await dependencies.workspace.urlForApplication(named: name)
    try checkCancellation()
    guard let url else { return nil }
    return try await openApplication(
      at: url, allowsRunningApplicationSubstitution: true,
      failureMessage: "Failed to launch application by name")
  }

  private func openApplication(
    at url: URL, allowsRunningApplicationSubstitution: Bool, failureMessage: String
  ) async throws(CancellationError) -> ActionResult {
    switch try await attemptOpeningApplication(
      at: url, expectedBundleIdentifier: nil,
      allowsRunningApplicationSubstitution: allowsRunningApplicationSubstitution)
    {
    case .opened: return .success
    case .staleRegistration, .failed: return openFailedResult(failureMessage)
    }
  }

  private func attemptOpeningApplication(
    at url: URL, expectedBundleIdentifier: String?, allowsRunningApplicationSubstitution: Bool
  ) async throws(CancellationError) -> ApplicationOpeningAttempt {
    try checkCancellation()
    do {
      try await dependencies.workspace.openApplication(
        at: url, activates: true, expectedBundleIdentifier: expectedBundleIdentifier,
        allowsRunningApplicationSubstitution: allowsRunningApplicationSubstitution)
    } catch {
      try checkCancellation()
      if error is CancellationError { throw CancellationError() }
      if expectedBundleIdentifier != nil, let launchError = error as? ApplicationLaunchError,
        launchError == .applicationBundleNotFound || launchError == .invalidApplicationBundleURL
      {
        return .staleRegistration
      }
      return .failed
    }
    try checkCancellation()
    return .opened
  }
}

private enum ApplicationPathResult {
  case valid(URL)
  case missing
  case invalid(String)
}

private enum ApplicationOpeningAttempt {
  case opened
  case staleRegistration
  case failed
}
