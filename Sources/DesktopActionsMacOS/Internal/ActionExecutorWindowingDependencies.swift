import DesktopActions
import WindowManagement
import WindowManagementMacOS

package enum FocusedWindowControlError: Error, Equatable, Sendable {
  case accessibilityNotTrusted
  case targetWindowUnavailable
  case invalidAccessibilityValue(String)
  case unsupportedAccessibilityOperation(String)
  case accessibilityOperationFailed(String)
  case displayNotFound(String)
  case unexpected(String)

  package init(_ error: WindowAccessibilityError) {
    switch error {
    case .accessibilityNotTrusted:
      self = .accessibilityNotTrusted
    case .applicationUnavailable, .windowUnavailable:
      self = .targetWindowUnavailable
    case .invalidAccessibilityValue(let operation):
      self = .invalidAccessibilityValue(operation.rawValue)
    case .unsupportedAccessibilityOperation(let operation):
      self = .unsupportedAccessibilityOperation(operation.rawValue)
    case .accessibilityOperationFailed(let operation, let failure):
      self = .accessibilityOperationFailed("\(operation.rawValue): \(failure.rawValue)")
    }
  }

  package init(_ error: WindowPlacerError) {
    switch error {
    case .displayNotFound(let screen):
      self = .displayNotFound(String(describing: screen))
    }
  }
}

package protocol FocusedWindowControlling: Sendable {
  @MainActor
  func requestClose() throws(FocusedWindowControlError)

  @MainActor
  func minimize() throws(FocusedWindowControlError)

  @MainActor
  func toggleFullScreen() throws(FocusedWindowControlError)

  @MainActor
  func place(_ request: WindowPlacementRequest) throws(FocusedWindowControlError)

  @MainActor
  func moveToAdjacentDisplay(_ request: WindowMoveRequest) throws(FocusedWindowControlError)
}
