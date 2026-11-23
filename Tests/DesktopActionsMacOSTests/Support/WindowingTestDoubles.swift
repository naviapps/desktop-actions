import DesktopActions
import DesktopActionsMacOS
import Foundation
import WindowManagement

final class TestFocusedWindowController: FocusedWindowControlling, @unchecked Sendable {
  private let lock = NSLock()
  private var placement: WindowPlacementRequest?
  private var move: WindowMoveRequest?
  private var minimizeCalls = 0
  private var toggleFullScreenCalls = 0
  private var closeCalls = 0
  private let closeError: FocusedWindowControlError?
  private let minimizeError: FocusedWindowControlError?
  private let toggleFullScreenError: FocusedWindowControlError?
  private let placeError: FocusedWindowControlError?
  private let moveError: FocusedWindowControlError?

  init(
    closeError: FocusedWindowControlError? = nil,
    placeError: FocusedWindowControlError? = nil,
    moveError: FocusedWindowControlError? = nil,
    minimizeError: FocusedWindowControlError? = nil,
    toggleFullScreenError: FocusedWindowControlError? = nil
  ) {
    self.closeError = closeError
    self.placeError = placeError
    self.moveError = moveError
    self.minimizeError = minimizeError
    self.toggleFullScreenError = toggleFullScreenError
  }

  @MainActor
  func requestClose() throws(FocusedWindowControlError) {
    if let closeError { throw closeError }
    lock.withLock { closeCalls += 1 }
  }

  var recordedCloseCalls: Int { lock.withLock { closeCalls } }

  @MainActor
  func minimize() throws(FocusedWindowControlError) {
    if let minimizeError { throw minimizeError }
    lock.withLock { minimizeCalls += 1 }
  }

  var recordedMinimizeCalls: Int { lock.withLock { minimizeCalls } }

  @MainActor
  func toggleFullScreen() throws(FocusedWindowControlError) {
    lock.withLock { toggleFullScreenCalls += 1 }
    if let toggleFullScreenError { throw toggleFullScreenError }
  }

  var recordedToggleFullScreenCalls: Int { lock.withLock { toggleFullScreenCalls } }

  @MainActor
  func place(_ request: WindowPlacementRequest) throws(FocusedWindowControlError) {
    if let placeError {
      throw placeError
    }
    lock.withLock {
      placement = request
    }
  }

  @MainActor
  func moveToAdjacentDisplay(_ request: WindowMoveRequest) throws(FocusedWindowControlError) {
    if let moveError {
      throw moveError
    }
    lock.withLock {
      move = request
    }
  }

  var recordedPlacement: WindowPlacementRequest? {
    lock.withLock {
      placement
    }
  }

  var recordedMove: WindowMoveRequest? {
    lock.withLock {
      move
    }
  }
}
