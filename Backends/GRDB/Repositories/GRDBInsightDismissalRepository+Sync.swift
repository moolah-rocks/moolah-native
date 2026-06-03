import Foundation
import GRDB

extension GRDBInsightDismissalRepository {
  /// Batch counterpart to `setEncodedSystemFieldsSync` — writes every update
  /// in a single transaction so `databaseDidCommit` fires once. See
  /// `GRDBAccountGroupRepository+Sync` and issue #865.
  func setEncodedSystemFieldsBatchSync(
    _ updates: [(id: UUID, data: Data?)]
  ) throws -> Int {
    guard !updates.isEmpty else { return 0 }
    return try database.write { database in
      var updatedCount = 0
      for (id, data) in updates {
        updatedCount +=
          try InsightDismissalRow
          .filter(InsightDismissalRow.Columns.id == id)
          .updateAll(
            database,
            [InsightDismissalRow.Columns.encodedSystemFields.set(to: data)])
      }
      return updatedCount
    }
  }
}
