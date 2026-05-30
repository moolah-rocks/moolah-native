import Foundation
import Observation
import os

/// `@Observable` sink for `DeepLinkDestination` values parsed by
/// `DeepLinkRouter`. Lives at app scope (one instance per `MoolahApp`) so
/// every window observes the same pending destination.
///
/// This task only stores the destination and logs it; Task 7 of the
/// share-import-extension plan replaces `handle(_:)` with the real flow
/// that drains the App Group inbox into `ImportStore.startWebReview`.
@MainActor
@Observable
public final class DeepLinkCoordinator {
  public private(set) var pendingDestination: DeepLinkDestination?

  private let logger = Logger(subsystem: "com.moolah.app", category: "DeepLinkCoordinator")

  public init() {}

  public func handle(_ destination: DeepLinkDestination) {
    logger.info("Deep link received: \(String(describing: destination), privacy: .public)")
    pendingDestination = destination
    // Task 7 will replace this with real handling — draining the inbox
    // and pushing the payload into `ImportStore.startWebReview(payload:)`.
  }
}
