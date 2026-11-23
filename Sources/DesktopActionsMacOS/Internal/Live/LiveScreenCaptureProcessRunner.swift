import Foundation
import Subprocess

struct LiveScreenCaptureProcessRunner: ScreenCaptureProcessRunning {
  private let executableURL: URL

  init(executableURL: URL = URL(fileURLWithPath: "/usr/sbin/screencapture")) {
    self.executableURL = executableURL
  }

  func run(arguments: [String]) async throws {
    try Task.checkCancellation()
    var options = PlatformOptions()
    options.teardownSequence = [
      .gracefulShutDown(allowedDurationToNextStep: .milliseconds(100))
    ]
    let result = try await Subprocess.run(
      .path(.init(executableURL.path)), arguments: .init(arguments),
      platformOptions: options, output: .discarded, error: .discarded)
    try Task.checkCancellation()
    switch result.terminationStatus {
    case .exited(0): return
    case .exited(let status), .signaled(let status):
      throw ScreenCaptureProcessFailure(terminationStatus: status)
    }
  }
}
