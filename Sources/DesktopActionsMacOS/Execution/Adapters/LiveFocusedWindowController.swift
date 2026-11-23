import DesktopActions
import WindowManagement
import WindowManagementMacOS

struct LiveFocusedWindowController: FocusedWindowControlling {
  private let closeWindow: @MainActor @Sendable () throws -> Void
  private let minimizeWindow: @MainActor @Sendable () throws -> Void
  private let toggleWindowFullScreen: @MainActor @Sendable () throws -> Void
  private let placeWindow: @MainActor @Sendable (WindowPlacementRequest) throws -> Void
  private let moveWindow: @MainActor @Sendable (WindowMoveRequest) throws -> Void

  init(
    requestClose: @escaping @MainActor @Sendable () throws -> Void = {
      try AXWindowController().requestClose(.focused)
    },
    minimize: @escaping @MainActor @Sendable () throws -> Void = {
      try AXWindowController().setMinimized(.focused, isMinimized: true)
    },
    toggleFullScreen: @escaping @MainActor @Sendable () throws -> Void = {
      try AXWindowController().toggleFullScreen(.focused)
    },
    place: @escaping @MainActor @Sendable (WindowPlacementRequest) throws -> Void = { request in
      try WindowPlacer().place(request, for: .focused, displayFallback: .none)
    },
    moveToAdjacentDisplay: @escaping @MainActor @Sendable (WindowMoveRequest) throws -> Void = {
      request in
      try WindowPlacer().moveToAdjacentDisplay(request, for: .focused, displayFallback: .none)
    }
  ) {
    closeWindow = requestClose
    minimizeWindow = minimize
    toggleWindowFullScreen = toggleFullScreen
    placeWindow = place
    moveWindow = moveToAdjacentDisplay
  }

  @MainActor
  func requestClose() throws(FocusedWindowControlError) {
    guard !Task.isCancelled else { return }
    do {
      try closeWindow()
    } catch let error as WindowAccessibilityError {
      throw FocusedWindowControlError(error)
    } catch {
      throw .unexpected(String(describing: error))
    }
  }

  @MainActor
  func minimize() throws(FocusedWindowControlError) {
    guard !Task.isCancelled else { return }
    do {
      try minimizeWindow()
    } catch let error as WindowAccessibilityError {
      throw FocusedWindowControlError(error)
    } catch {
      throw .unexpected(String(describing: error))
    }
  }

  @MainActor
  func toggleFullScreen() throws(FocusedWindowControlError) {
    guard !Task.isCancelled else { return }
    do {
      try toggleWindowFullScreen()
    } catch let error as WindowAccessibilityError {
      throw FocusedWindowControlError(error)
    } catch {
      throw .unexpected(String(describing: error))
    }
  }

  @MainActor
  func place(_ request: WindowPlacementRequest) throws(FocusedWindowControlError) {
    guard !Task.isCancelled else { return }
    do {
      try placeWindow(request)
    } catch let error as WindowPlacerError {
      throw FocusedWindowControlError(error)
    } catch let error as WindowAccessibilityError {
      throw FocusedWindowControlError(error)
    } catch {
      throw .unexpected(String(describing: error))
    }
  }

  @MainActor
  func moveToAdjacentDisplay(_ request: WindowMoveRequest) throws(FocusedWindowControlError) {
    guard !Task.isCancelled else { return }
    do {
      try moveWindow(request)
    } catch let error as WindowPlacerError {
      throw FocusedWindowControlError(error)
    } catch let error as WindowAccessibilityError {
      throw FocusedWindowControlError(error)
    } catch {
      throw .unexpected(String(describing: error))
    }
  }
}
