import DesktopApplications
import DesktopApplicationsMacOS

struct LiveFrontmostApplicationController: FrontmostApplicationControlling {
  private let hideFrontmost: @MainActor @Sendable () -> FrontmostApplicationControlResult
  private let terminateFrontmost: @MainActor @Sendable () -> FrontmostApplicationControlResult

  init(
    hideFrontmost: @escaping @MainActor @Sendable () -> FrontmostApplicationControlResult = {
      Self.controlFrontmostApplication { $0.hideApplication($1) }
    },
    terminateFrontmost: @escaping @MainActor @Sendable () -> FrontmostApplicationControlResult = {
      Self.controlFrontmostApplication { $0.terminateApplication($1, mode: .graceful) }
    }
  ) {
    self.hideFrontmost = hideFrontmost
    self.terminateFrontmost = terminateFrontmost
  }

  func hideFrontmostApplication() async -> FrontmostApplicationControlResult {
    await MainActor.run {
      guard !Task.isCancelled else { return .failed }
      return hideFrontmost()
    }
  }

  func terminateFrontmostApplication() async -> FrontmostApplicationControlResult {
    await MainActor.run {
      guard !Task.isCancelled else { return .failed }
      return terminateFrontmost()
    }
  }

  @MainActor
  private static func controlFrontmostApplication(
    _ command: (ApplicationManager, ApplicationSnapshot) -> ApplicationRequestResult<
      ApplicationOperationError
    >
  ) -> FrontmostApplicationControlResult {
    let manager = ApplicationManager()
    guard let application = manager.frontmostApplication() else { return .noFrontmostApplication }
    switch command(manager, application) {
    case .requestAccepted: return .success
    case .failed: return .failed
    }
  }
}
