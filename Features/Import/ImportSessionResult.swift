import Foundation

/// Result of a single `ingest` call. `ImportStore.recentSessions` retains
/// recent import summaries and acts as a refresh signal for Recently Added.
enum ImportSessionResult: Sendable {
  case imported(sessionId: UUID, imported: [Transaction], skippedAsDuplicate: Int)
  case needsSetup(pendingId: UUID)
  case cancelled
  case retryLater(message: String)
  case failed(message: String)
}
