import DesktopApplicationsMacOS

final class LiveSystemEventsLauncher: SystemEventsLaunching {
  static let shared = LiveSystemEventsLauncher()

  private let coordinator: SystemEventsLaunchCoordinator

  init(
    isRunning: @escaping @Sendable () async -> Bool = {
      await MainActor.run {
        !ApplicationManager().runningApplications(
          bundleIdentifier: SystemEventsLaunchCoordinator.bundleIdentifier
        ).isEmpty
      }
    },
    launch: @escaping @Sendable () async -> Void = {
      await SystemEventsLaunchCoordinator.launchSystemEvents()
    },
    sleep: @escaping @Sendable (UInt64) async -> Void = { nanoseconds in
      try? await Task.sleep(nanoseconds: nanoseconds)
    }
  ) {
    coordinator = SystemEventsLaunchCoordinator(
      isRunning: isRunning,
      launch: launch,
      sleep: sleep
    )
  }

  func ensureRunning() async -> Bool {
    await coordinator.ensureRunning()
  }
}
