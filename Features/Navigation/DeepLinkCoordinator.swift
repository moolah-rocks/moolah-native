import Foundation
import ImportExtensionKit
import Observation
import os

/// `@Observable` sink for `DeepLinkDestination` values parsed by
/// `DeepLinkRouter`. Lives at app scope (one instance per `MoolahApp`) so
/// every window observes the same pending destination.
///
/// On a `.importInbox` destination the coordinator drains the App Group
/// inbox (`InboxWriter.shared()`), forwards the payload to
/// `ImportStore.startWebReview(payload:)`, and deletes the inbox file
/// regardless of import outcome — the JSON has already been claimed by the
/// pipeline, which routes failures into the staging store. The
/// `importStoreProvider` is a closure rather than a stored reference
/// because the active `ImportStore` belongs to the active
/// `ProfileSession` and changes when the user switches profiles; the main
/// app resolves the current session at call time.
@MainActor
@Observable
public final class DeepLinkCoordinator {
  /// Last destination the router handed in. Retained so a deep link that
  /// arrives while no profile session is open can be replayed once a
  /// session is available.
  public private(set) var pendingDestination: DeepLinkDestination?

  /// Resolver for the currently active `ImportStore`. Returns `nil` when
  /// no profile session is open (e.g. on the Welcome view); in that case
  /// the destination is retained as `pendingDestination` for replay.
  private let importStoreProvider: @MainActor () -> ImportStore?
  /// Inbox source. Defaulted to `InboxWriter.shared` so production wiring
  /// is a no-op; tests inject a temp-directory `InboxWriter`.
  private let inboxProvider: @Sendable () -> InboxWriter?
  private let logger = Logger(subsystem: "com.moolah.app", category: "DeepLinkCoordinator")

  /// Public init for the no-arg / stubbed case (previews, tests that don't
  /// exercise the inbox-drain path). Production constructs the coordinator
  /// via the internal initialiser in `MoolahApp.init` so the
  /// `importStoreProvider` closure can capture the (internal) session
  /// manager.
  public convenience init() {
    self.init(
      importStoreProvider: { nil },
      inboxProvider: { InboxWriter.shared() })
  }

  init(
    importStoreProvider: @escaping @MainActor () -> ImportStore?,
    inboxProvider: @escaping @Sendable () -> InboxWriter? = { InboxWriter.shared() }
  ) {
    self.importStoreProvider = importStoreProvider
    self.inboxProvider = inboxProvider
  }

  public func handle(_ destination: DeepLinkDestination) async {
    logger.info("Deep link received: \(String(describing: destination), privacy: .public)")
    pendingDestination = destination
    switch destination {
    case .importInbox(let id):
      await drainInbox(id: id)
    }
  }

  /// Read the payload at `id` from the inbox, hand it to the active
  /// `ImportStore`, then delete the inbox file. The delete runs whether the
  /// import succeeded or staged-as-failed because the payload has been
  /// fully consumed in both cases — the failed-files panel owns recovery
  /// from there.
  private func drainInbox(id: UUID) async {
    guard let inbox = inboxProvider() else {
      logger.error("App Group inbox unavailable; cannot drain \(id, privacy: .public)")
      return
    }
    guard let store = importStoreProvider() else {
      // No active session; pendingDestination is held for replay once a
      // session opens. The payload stays on disk until then.
      logger.info(
        "No active ImportStore; deferring inbox drain for \(id, privacy: .public)")
      return
    }
    let payload: ImportPayload
    do {
      payload = try inbox.read(id: id)
    } catch {
      logger.error(
        "Failed to read inbox \(id, privacy: .public): \(String(describing: error), privacy: .public)"
      )
      // `InboxWriter.read` quarantines and removes the file itself on a
      // decode failure; nothing to clean up here.
      return
    }
    _ = await store.startWebReview(payload: payload)
    do {
      try inbox.delete(id: id)
    } catch {
      logger.error(
        "Failed to delete inbox \(id, privacy: .public) after drain: \(String(describing: error), privacy: .public)"
      )
    }
    // Clear the latch once the payload has been claimed.
    if pendingDestination == .importInbox(id) {
      pendingDestination = nil
    }
  }
}
