import Foundation

extension ActionKind {
  /// Creates an input-free request, or `nil` when this kind requires input.
  public func makeAction() -> ActionRequest? { makeRequest(input: nil) }

  /// Creates a request through Rust's kind, shape and value validation boundary.
  /// Returns `nil` when the input is missing, blank or has the wrong shape.
  public func makeAction(input: ActionInput) -> ActionRequest? { makeRequest(input: input) }

  private func makeRequest(input: ActionInput?) -> ActionRequest? {
    guard let data = try? JSONEncoder().encode(ActionRequest.Projection(kind: self, input: input))
    else { return nil }
    return try? JSONDecoder().decode(ActionRequest.self, from: data)
  }
}
