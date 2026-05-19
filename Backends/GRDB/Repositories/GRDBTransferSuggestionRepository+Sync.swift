import Foundation
import GRDB

extension GRDBTransferSuggestionRepository {
  /// Batch counterpart to `setEncodedSystemFieldsSync` — writes every
  /// update in a single GRDB transaction so `databaseDidCommit` fires
  /// once rather than once per row. See the doc on
  /// `GRDBCategoryRepository.setEncodedSystemFieldsBatchSync` for the
  /// rationale and issue #865 for the follow-up that drops the
  /// observation-region dependency on this column.
  func setEncodedSystemFieldsBatchSync(
    _ updates: [(id: UUID, data: Data?)]
  ) throws -> Int {
    guard !updates.isEmpty else { return 0 }
    return try database.write { database in
      var updatedCount = 0
      for (id, data) in updates {
        updatedCount +=
          try TransferSuggestionRow
          .filter(TransferSuggestionRow.Columns.id == id)
          .updateAll(
            database,
            [TransferSuggestionRow.Columns.encodedSystemFields.set(to: data)])
      }
      return updatedCount
    }
  }
}
