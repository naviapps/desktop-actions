import DesktopActions

extension ActionExecutor {
  func executeHideFrontmostApplication() async throws(CancellationError) -> ActionResult {
    try checkCancellation()
    let result = await dependencies.frontmostApplicationController.hideFrontmostApplication()
    try checkCancellation()
    return frontmostApplicationResult(
      result,
      failureMessage: "Failed to hide frontmost application"
    )
  }

  func executeTerminateFrontmostApplication() async throws(CancellationError) -> ActionResult {
    try checkCancellation()
    let result = await dependencies.frontmostApplicationController.terminateFrontmostApplication()
    try checkCancellation()
    return frontmostApplicationResult(
      result,
      failureMessage: "Failed to terminate frontmost application"
    )
  }

  private func frontmostApplicationResult(
    _ result: FrontmostApplicationControlResult,
    failureMessage: String
  ) -> ActionResult {
    switch result {
    case .success:
      return .success
    case .noFrontmostApplication:
      return .skipped(.noFrontmostApplication)
    case .failed:
      return internalErrorResult(failureMessage)
    }
  }
}
