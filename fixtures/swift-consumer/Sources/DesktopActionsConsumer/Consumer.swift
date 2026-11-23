import DesktopActions
import DesktopActionsMacOS
import DesktopActionsSwiftUI
import Foundation

private struct AcceptanceFailure: Error {
  let message: String
}

private func require(_ condition: Bool, _ message: String) throws {
  guard condition else { throw AcceptanceFailure(message: message) }
}

@main
struct DesktopActionsConsumer {
  static func main() async throws {
    let action = ActionRequest.openURL("https://example.com")
    let encoded = try ActionCodec.encode(action)
    let decoded = try ActionCodec.decode(encoded)
    try require(decoded == action, "The action codec did not preserve the request")
    let example = ActionKind.openURL.inputDescriptor.exampleInput
    let catalogAction = example.flatMap { ActionKind.openURL.makeAction(input: $0) }
    try require(
      catalogAction?.input == action.input, "Typed catalog input did not create the request")
    let tagged = try JSONEncoder().encode(ActionInput.string(" \thttps://example.com \n"))
    let restoredInput = try ActionCodec.decodeInput(tagged)
    try require(restoredInput == action.input, "Standalone typed input was not normalized")
    let bare = try ActionCodec.decodeRequest(JSONEncoder().encode(action))
    let padded = try ActionCodec.decodeRequest(
      Data(#"{"kind":"action.workspace.open-url","input":" https://example.com "}"#.utf8))
    try require(
      Set([action, decoded, bare, padded]).count == 1,
      "Independently decoded canonical requests did not compare by value")
    try require(ActionPreflight.isExecutable(action), "The URL request has no executable plan")
    let permissions = ActionPreflight.permissions(for: action)
    try require(permissions.primary.isEmpty, "URL preflight invented a privacy requirement")
    let placementPreview = ActionPreflight.inspectKind(.windowPlacement)
    try require(
      placementPreview.permissionHints.first?.reason == .accessibilityWindowing,
      "Catalog preview needs to expose placement permissions before input")
    let windows = ActionRequest.lockScreen.plan(for: .windows)
    try require(windows.platform == .windows && windows.isExecutable, "Windows plan unavailable")
    try require(windows.steps.first?.method == .lockSession, "Windows instruction unavailable")
    try require(windows.permissionRequirements.isEmpty, "Windows plan claimed macOS permissions")
    let composedPath = ActionRequest.openFolder("/tmp/caf\u{E9}")
    let decomposedPath = ActionRequest.openFolder("/tmp/cafe\u{301}")
    try require(
      Set([composedPath, decomposedPath]).count == 2
        && Set([composedPath.plan(for: .macOS), decomposedPath.plan(for: .macOS)]).count == 2,
      "Value equality merged different UTF-8 folder paths")
    try require(
      !ActionPreflight.isExecutable(.keyboardShortcut("cmd+unknown-key")),
      "Preflight accepted an invalid physical shortcut")

    do {
      _ = try ActionCodec.decode(Data(#"{"version":999}"#.utf8))
      throw AcceptanceFailure(message: "The action codec accepted an unsupported version")
    } catch let error as ActionCodecError {
      try require(error == .unsupportedVersion(999), "The codec lost its public version error")
    }

    do {
      _ = try ActionRunner(maximumConcurrentExecutions: 0, timeout: .seconds(5))
      throw AcceptanceFailure(message: "The runner accepted an invalid capacity")
    } catch let error as ActionRunner.ConfigurationError {
      try require(error == .invalidCapacity, "The runner lost its public configuration error")
    }

    let runner = try ActionRunner(maximumConcurrentExecutions: 1, timeout: .seconds(5))
    let outcome = await runner.run(action) { request in
      ActionExecutionReport(
        result: request == action ? .success : .failure(.permissionDenied(.accessibility)))
    }
    try require(
      outcome == .completed(ActionExecutionReport(result: .success)),
      "The runner did not deliver the injected operation result")
    let sequence = await runner.runSequence([action], failureBehavior: .continue) { _ in
      ActionExecutionReport(result: .success)
    }
    try require(
      sequence.status == .completed && sequence.results == [outcome]
        && sequence.allActionsSucceeded,
      "The sequence did not preserve the injected result")

    let failure = ActionExecutionReport(result: .failure(.invalidInput("caf\u{E9}")))
    let decodedFailure = try ActionResultCodec.decodeExecutionReport(
      ActionResultCodec.encode(failure))
    let differentSpelling = ActionExecutionReport(result: .failure(.invalidInput("cafe\u{301}")))
    try require(
      Set([failure, decodedFailure, differentSpelling]).count == 2,
      "Execution report equality did not preserve the Rust diagnostic spelling")

    // Construct configuration only; no live executor or permission API is invoked.
    let configuration = ActionExecutorConfiguration(
      permissions: .init(
        ensureAccessibility: { false }, ensureAutomation: { false },
        onAutomationDenied: { _ in }, onScreenRecordingRequired: {}))
    let accessibilityReady = await configuration.permissions.ensureAccessibility()
    let automationReady = await configuration.permissions.ensureAutomation()
    try require(!accessibilityReady && !automationReady, "The injected permission hooks changed")
    try require(ActionKind.openURL.standardSystemImage == "link", "The standard symbol changed")
    print(
      "Standalone DesktopActions, DesktopActionsMacOS and DesktopActionsSwiftUI acceptance passed."
    )
  }
}
