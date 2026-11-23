import Foundation
import Subprocess

/// Owns a cancellable script process; NSAppleScript must not run on detached threads.
struct LiveAppleScriptExecutor: AppleScriptExecuting {
  private let executableURL: URL

  init(executableURL: URL = URL(fileURLWithPath: "/usr/bin/osascript")) {
    self.executableURL = executableURL
  }

  func execute(source: String) async throws(CancellationError) -> Result<
    Void, AppleScriptExecutionFailure
  > {
    if Task.isCancelled { throw CancellationError() }
    do {
      var options = PlatformOptions()
      options.teardownSequence = [.gracefulShutDown(allowedDurationToNextStep: .milliseconds(100))]
      let result = try await Subprocess.run(
        .path(.init(executableURL.path)), arguments: .init(["-l", "AppleScript", "-e", source]),
        platformOptions: options, output: .discarded, error: .data(limit: 65_536))
      if Task.isCancelled { throw CancellationError() }
      guard result.terminationStatus.isSuccess else {
        return .failure(.init(appleScriptErrorNumber: Self.errorNumber(in: result.standardError)))
      }
      return .success(())
    } catch {
      if Task.isCancelled || error is CancellationError { throw CancellationError() }
      // Do not expose raw stderr, script text, arguments or unbounded child output.
      return .failure(.init(message: "AppleScript process could not complete"))
    }
  }

  private static func errorNumber(in data: Data) -> Int? {
    guard let text = String(data: data, encoding: .utf8),
      let range = text.range(of: #"\(-?[0-9]+\)\s*$"#, options: .regularExpression)
    else { return nil }
    let suffix = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
    return Int(suffix.dropFirst().dropLast())
  }
}
