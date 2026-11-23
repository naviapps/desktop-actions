import Foundation

struct RustPlanMetadata: Decodable, Sendable, Equatable, Hashable {
  let isExecutable: Bool
  let permissions: ActionPermissionSet
  let hints: [ActionPermissionHint]
}
enum RustActionPlanning {
  private struct Report: Decodable {
    let platform: ActionPlatform
    let isExecutable: Bool
    let steps: [ActionStep]
    let permissions: ActionPermissionSet
    let hints: [ActionPermissionHint]
  }
  static func plan(for action: ActionRequest, on platform: ActionPlatform) -> ActionPlan {
    do {
      let data = try RustActionJSON.plan(
        JSONEncoder().encode(ActionRequest.Projection(kind: action.kind, input: action.input)),
        for: platform)
      return try decodePlan(data, on: platform)
    } catch let error as ActionCodecError {
      // Swift enum cases can contain invalid direct input. Preserve the Rust error
      // as a non-executable failure instruction instead of entering a native effect.
      return .init(
        steps: [.init(method: .invalidInput(error.localizedDescription))], platform: platform)
    } catch {
      preconditionFailure("Native action planning facade mismatch: \(error)")
    }
  }
  static func plan(forKind kind: ActionKind, on platform: ActionPlatform) -> ActionPlan {
    do {
      return try decodePlan(RustActionJSON.kindPlan(kind.identifier, for: platform), on: platform)
    } catch {
      preconditionFailure("Native catalog planning facade mismatch: \(error)")
    }
  }
  private static func decodePlan(_ data: Data, on platform: ActionPlatform) throws -> ActionPlan {
    let report = try JSONDecoder().decode(Report.self, from: data)
    precondition(report.platform == platform, "Native action plan targets another platform")
    return .init(
      platform: report.platform,
      steps: report.steps,
      metadata: .init(
        isExecutable: report.isExecutable, permissions: report.permissions, hints: report.hints))
  }
  static func metadata(for steps: [ActionStep], on platform: ActionPlatform = .macOS)
    -> RustPlanMetadata
  {
    do {
      return try JSONDecoder().decode(
        RustPlanMetadata.self,
        from: RustActionJSON.planMetadata(JSONEncoder().encode(steps), for: platform))
    } catch {
      preconditionFailure("Native plan metadata facade mismatch: \(error)")
    }
  }
}
