import DesktopActions

extension ActionExecutor {
  func executeScreenCapture(arguments: [String]) async throws(CancellationError) -> ActionResult {
    do {
      try await dependencies.screenCaptureProcessRunner.run(arguments: arguments)
      return .success
    } catch let cancellation as CancellationError {
      throw cancellation
    } catch {
      try checkCancellation()
      return failureResult(
        .screenCaptureFailed(
          Self.screenCaptureFailureMessage(
            terminationStatus: (error as? ScreenCaptureProcessFailure)?.terminationStatus)
        ),
        logLevel: .error
      )
    }
  }

  private static func screenCaptureFailureMessage(terminationStatus: Int32?) -> String {
    guard let terminationStatus else { return "Screen capture failed" }
    return "Screen capture failed with termination status \(terminationStatus)"
  }
}
