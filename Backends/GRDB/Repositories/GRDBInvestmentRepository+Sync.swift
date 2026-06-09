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
}
