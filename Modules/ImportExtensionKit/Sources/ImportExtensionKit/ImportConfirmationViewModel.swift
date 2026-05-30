import Foundation

@MainActor
public final class ImportConfirmationViewModel {
  public enum State: Equatable, Sendable {
    case success(rows: Int, displayName: String)
    case emptyResult(displayName: String)
    case schemaMismatch
    case writeFailed
  }

  public let state: State

  public init(payload: ImportPayload, registry: PluginRegistry) {
    let manifest = registry.match(host: payload.sourceHost, path: "/")
    let name = manifest?.displayName ?? payload.sourceHost
    if payload.rows.isEmpty {
      self.state = .emptyResult(displayName: name)
    } else {
      self.state = .success(rows: payload.rows.count, displayName: name)
    }
  }

  public init(state: State) {
    self.state = state
  }
}
