import Foundation
import GRDB

// Deletion-journal (issue #1090) helpers for the transaction repository.
// Centralised so the create / createMany / replace / update / delete sites
// stay one-liners and under the type/closure body-length limits, and so the
// header+leg record/clear policy lives in exactly one place.

extension GRDBTransactionRepository {
  /// Clears stale deletion intents for a (re-)created header and its legs
  /// (D1-b): a row re-created under its own id drops its own tombstone in the
  /// SAME write, so a start-time replay can't delete the live record.
  static func clearDeletionIntents(
    for transaction: Transaction, in database: Database
  ) throws {
    try DeletionJournal.clearDataDeletion(
      recordName: TransactionRow.recordName(for: transaction.id), in: database)
    for leg in transaction.legs {
      try clearLegDeletionIntent(leg.id, in: database)
    }
  }

  /// Clears a single leg's deletion intent (the in-place update upsert path).
  static func clearLegDeletionIntent(_ legId: UUID, in database: Database) throws {
    try DeletionJournal.clearDataDeletion(
      recordName: TransactionLegRow.recordName(for: legId), in: database)
  }

  /// Records durable deletion intents for a header and its legs, in the SAME
  /// write as the row deletes (issue #1090).
  static func recordTransactionDeletion(
    headerId: UUID, legIds: [UUID], in database: Database
  ) throws {
    try DeletionJournal.recordDataDeletion(
      recordName: TransactionRow.recordName(for: headerId),
      recordType: TransactionRow.recordType,
      at: Date(),
      in: database)
    for legId in legIds {
      try recordLegDeletion(legId, in: database)
    }
  }

  /// Records a durable deletion intent for a single leg (issue #1090).
  static func recordLegDeletion(_ legId: UUID, in database: Database) throws {
    try DeletionJournal.recordDataDeletion(
      recordName: TransactionLegRow.recordName(for: legId),
      recordType: TransactionLegRow.recordType,
      at: Date(),
      in: database)
  }
}
