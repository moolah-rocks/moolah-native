import Foundation
import Observation

/// View model for `ImportConfirmationView`. `@Observable` because the
/// controller mutates `state` after the view is already on screen — most
/// notably a `.success` → `.writeFailed` transition when the inbox write
/// fails on a `Review Later` or `Open Moolah` tap. Construct with
/// `init(payload:registry:)` for the loaded-payload happy path or
/// `init(state:)` for the schema-mismatch / write-failed seed.
@MainActor
@Observable
public final class ImportConfirmationViewModel {
  public enum State: Equatable, Sendable {
    case success(rows: Int, displayName: String)
    case emptyResult(displayName: String)
    case schemaMismatch
    case writeFailed
  }

  public private(set) var state: State

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

  /// Mutates `state` in place so observers (SwiftUI `ImportConfirmationView`
  /// already on screen) re-render. Used by `PrincipalController` when an
  /// inbox write fails after the success view has been presented.
  public func update(state: State) {
    self.state = state
  }
}
