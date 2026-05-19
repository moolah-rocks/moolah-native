import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("ProfileSchema v13 transfer suggestion")
struct ProfileSchemaV13TransferSuggestionTests {
  @Test("v13 creates transfer_suggestion, drops dismissed_transfer_pair and the 2 tx columns")
  func v13Shape() async throws {
    let database = try ProfileDatabase.openInMemory()
    try await database.read { database in
      let cols = try Row.fetchAll(database, sql: "PRAGMA table_info(transfer_suggestion)")
        .map { $0["name"] as String }
      #expect(
        Set(cols) == [
          "id", "record_name", "transaction_id_a", "transaction_id_b",
          "suggested_at", "encoded_system_fields",
        ])
      let hasOld =
        try Int.fetchOne(
          database,
          sql: """
            SELECT count(*) FROM sqlite_master
            WHERE type='table' AND name='dismissed_transfer_pair'
            """) ?? -1
      #expect(hasOld == 0)
      let txCols = try Row.fetchAll(database, sql: "PRAGMA table_info(\"transaction\")")
        .map { $0["name"] as String }
      #expect(!txCols.contains("transfer_suggestion_counterpart_id"))
      #expect(!txCols.contains("transfer_suggestion_suggested_at"))
    }
  }

  @Test("suggestions lookup uses the tx indexes, not a scan")
  func suggestionLookupUsesIndex() async throws {
    let database = try ProfileDatabase.openInMemory()
    let txId = UUID()
    try await database.read { database in
      let plan = try Row.fetchAll(
        database,
        sql: """
          EXPLAIN QUERY PLAN
          SELECT * FROM transfer_suggestion
          WHERE transaction_id_a = ? OR transaction_id_b = ?
          """,
        arguments: [txId, txId]
      ).map { String(describing: $0["detail"] ?? "") }
      #expect(plan.contains { $0.contains("USING INDEX transfer_suggestion_by_tx_") })
      #expect(!plan.contains { $0.contains("SCAN transfer_suggestion") })
    }
  }
}
