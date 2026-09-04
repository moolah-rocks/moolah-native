import Foundation

/// Summary of a recent import session for the UI.
struct ImportSessionSummary: Sendable, Identifiable, Hashable {
  var id: UUID
  var importedCount: Int
  var skippedAsDuplicate: Int
  var importedAt: Date
  var filename: String?
}
