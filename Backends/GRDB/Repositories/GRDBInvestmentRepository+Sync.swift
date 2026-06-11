import Foundation
import GRDB

// In-transaction sync helpers for the upload-ack compare-and-clear path
// (issue #1081). Split out of `GRDBInvestmentRepository.swift` to keep
// that type's body under the 250-line limit.

extension GRDBInvestmentRepository {
  /// In-transaction counterpart to `clearNeedsPushBatchSync(_:)` — see
  /// `GRDBAccountRepository` for the atomic compare-and-clear rationale
  /// (issue #1081).
  @discardableResult
  func clearNeedsPushBatchSync(_ ids: [UUID], in database: Database) throws -> Int {
    guard !ids.isEmpty else { return 0 }
    return
      try InvestmentValueRow
      .filter(Set(ids).contains(InvestmentValueRow.Columns.id))
      .updateAll(database, [InvestmentValueRow.Columns.needsPush.set(to: false)])
  }

  /// In-transaction counterpart to `fetchRowSync(id:)` (issue #1081).
  func fetchRowSync(id: UUID, in database: Database) throws -> InvestmentValueRow? {
    try InvestmentValueRow
      .filter(InvestmentValueRow.Columns.id == id)
      .fetchOne(database)
  }

  func applyRemoteChangesSync(
    saved rows: [InvestmentValueRow], deleted ids: [UUID]
  ) throws {
    try database.write { database in
      try applyRemoteChangesSync(saved: rows, deleted: ids, in: database)
    }
  }

  /// In-transaction variant — see `GRDBCSVImportProfileRepository.applyRemoteChangesSync(...:in:)`
  /// for the rationale (one commit per `applyRemoteChanges` batch, issue #872).
  func applyRemoteChangesSync(
    saved rows: [InvestmentValueRow], deleted ids: [UUID], in database: Database
  ) throws {
    for row in rows {
      try row.upsert(database)
      // D1-b (issue #1090): a peer re-creating clears our stale intent; the
      // apply-path delete below is server-originated and never journaled.
      try DeletionJournal.clearDataDeletion(recordName: row.recordName, in: database)
    }
    for id in ids {
      _ = try InvestmentValueRow.deleteOne(database, id: id)
    }
  }
}
