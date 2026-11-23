import CDesktopActions
import Foundation

/// The Rust mutex protects reducer state; Swift owns only this native lifetime.
package final class ActionExecutionContext: @unchecked Sendable {
  package struct Next: Decodable {
    package let id: UInt64
    package let step: ActionStep
  }
  package struct Report: Decodable {
    package let outcome: ActionExecutionReport
    package let notifyAutomationDenied: Bool
    package let automationErrorNumber: Int?
  }
  private let owner: OpaquePointer
  package convenience init(action: ActionRequest) {
    do {
      try self.init(
        data: JSONEncoder().encode(
          ActionRequest.Projection(kind: action.kind, input: action.input)),
        kind: 0)
    } catch { preconditionFailure("Native action run input mismatch: \(error)") }
  }
  package convenience init(plan: ActionPlan) {
    do { try self.init(data: JSONEncoder().encode(plan.steps), kind: 1) } catch {
      preconditionFailure("Native action run plan mismatch: \(error)")
    }
  }
  private init(data: Data, kind: UInt32) throws {
    guard
      let value = data.withUnsafeBytes({ bytes in
        desktop_actions_run_create(
          bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, 0, kind)
      })
    else { throw ActionCodecError.invalidData("Native action run could not be created.") }
    owner = value
  }
  deinit { desktop_actions_run_destroy(owner) }
  package func next() -> Next? {
    do {
      return try JSONDecoder().decode(
        Next?.self, from: RustActionJSON.take(desktop_actions_run_next(owner)))
    } catch { preconditionFailure("Native action run sequencing mismatch: \(error)") }
  }
  package func record(_ result: ActionResult, id: UInt64, duration: Duration) {
    do {
      let data = try JSONEncoder().encode(result)
      let seconds = ActionAttempt.wireSeconds(duration)
      let status = data.withUnsafeBytes { bytes in
        desktop_actions_run_record(
          owner, id, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, seconds, 1)
      }
      precondition(status == 0, "Native action run rejected its outstanding result")
    } catch { preconditionFailure("Native action result facade mismatch: \(error)") }
  }
  package func report() -> Report {
    do {
      return try JSONDecoder().decode(
        Report.self, from: RustActionJSON.take(desktop_actions_run_report(owner)))
    } catch { preconditionFailure("Native action outcome facade mismatch: \(error)") }
  }
}
