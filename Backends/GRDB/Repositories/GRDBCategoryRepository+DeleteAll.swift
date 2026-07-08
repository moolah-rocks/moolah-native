// Backends/GRDB/Repositories/GRDBCategoryRepository+DeleteAll.swift

import GRDB

extension GRDBCategoryRepository {
  /// Deletes every row in the table. Used by `deleteLocalData` after a
  /// remote zone deletion.
  func deleteAllSync() throws {
    try database.write { database in
      _ = try CategoryTaxOwnerRow.deleteAll(database)
      _ = try CategoryRow.deleteAll(database)
    }
  }
}
