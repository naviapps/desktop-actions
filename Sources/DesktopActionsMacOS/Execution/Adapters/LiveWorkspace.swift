import AppKit
import Darwin
import DesktopApplications
import DesktopApplicationsMacOS
import Foundation

struct LiveWorkspace: WorkspaceControlling {
  private let applicationSearchDirectories: [String]
  private let requestOpening:
    @MainActor @Sendable (URL, NSWorkspace.OpenConfiguration) async throws -> Void

  init(
    applicationSearchDirectories: [String] = ApplicationManager.defaultSearchDirectories,
    requestOpening:
      @escaping @MainActor @Sendable (URL, NSWorkspace.OpenConfiguration) async throws -> Void =
      Self.requestApplicationOpening
  ) {
    self.applicationSearchDirectories = applicationSearchDirectories
    self.requestOpening = requestOpening
  }

  func open(_ url: URL) async -> Bool {
    await MainActor.run {
      guard !Task.isCancelled else { return false }
      return NSWorkspace.shared.open(url)
    }
  }

  func urlForApplication(bundleIdentifier: String) async -> URL? {
    await MainActor.run {
      guard !Task.isCancelled else { return nil }
      return ApplicationManager().installedApplicationURL(bundleIdentifier: bundleIdentifier)
    }
  }

  func urlsForApplications(bundleIdentifier: String) async -> [URL] {
    await MainActor.run {
      guard !Task.isCancelled else { return [] }
      return ApplicationManager().installedApplicationURLs(bundleIdentifier: bundleIdentifier)
    }
  }

  func urlForApplication(named name: String) async -> URL? {
    await MainActor.run {
      guard !Task.isCancelled else { return nil }
      return ApplicationManager().installedApplicationURL(
        named: name, searchDirectories: applicationSearchDirectories)
    }
  }

  @MainActor
  func openApplication(
    at url: URL, activates: Bool, expectedBundleIdentifier: String?,
    allowsRunningApplicationSubstitution: Bool
  ) async throws {
    try Task.checkCancellation()
    if let expectedBundleIdentifier {
      let identifier = Self.currentBundleIdentifier(at: url)
      try Task.checkCancellation()
      guard identifier == expectedBundleIdentifier else {
        throw ApplicationLaunchError.invalidApplicationBundleURL
      }
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = activates
    configuration.allowsRunningApplicationSubstitution = allowsRunningApplicationSubstitution
    try await requestOpening(url, configuration)
  }

  @MainActor
  private static func requestApplicationOpening(
    at url: URL, configuration: NSWorkspace.OpenConfiguration
  ) async throws {
    try Task.checkCancellation()
    switch try await ApplicationManager().openApplication(at: url, configuration: configuration) {
    case .requestAccepted: return
    case .failed(let error): throw error
    }
  }

  // Bundle(url:) caches Info.plist by URL. A stale registration can now point
  // to a different application, so read the candidate's current bytes.
  private static func currentBundleIdentifier(at applicationURL: URL) -> String? {
    guard applicationURL.isFileURL, applicationURL.pathExtension.lowercased() == "app" else {
      return nil
    }
    let infoURL = applicationURL.appendingPathComponent("Contents/Info.plist")
    let descriptor = infoURL.withUnsafeFileSystemRepresentation { path in
      guard let path else { return Int32(-1) }
      return Darwin.open(path, O_RDONLY | O_NONBLOCK | O_NOCTTY | O_CLOEXEC)
    }
    guard descriptor >= 0 else { return nil }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    let limit = 4 * 1024 * 1024
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_size <= limit
    else { return nil }
    var data = Data()
    while data.count <= limit {
      let chunk: Data
      do {
        chunk = try file.read(upToCount: min(limit - data.count + 1, 64 * 1024)) ?? Data()
      } catch { return nil }
      if chunk.isEmpty {
        let info = try? PropertyListSerialization.propertyList(from: data, format: nil)
        return (info as? [String: Any])?["CFBundleIdentifier"] as? String
      }
      data.append(chunk)
    }
    return nil
  }
}
