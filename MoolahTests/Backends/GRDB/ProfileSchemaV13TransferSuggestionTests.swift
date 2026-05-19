import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("ProfileSchema v13 transfer suggestion")
struct ProfileSchemaV13TransferSuggestionTests {
  @Test("v13 creates the transfer_suggestion table with its six columns")
  func createsTransferSuggestionTable() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue)
    try queue.read { database in
      let cols = try Set(database.columns(in: "transfer_suggestion").map(\.name))
      #expect(
        cols == [
          "id", "record_name", "transaction_id_a", "transaction_id_b",
          "suggested_at", "encoded_system_fields",
        ])
    }
  }

  @Test("v13 drops the dismissed_transfer_pair table")
  func dropsDismissedTransferPairTable() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue)
    try queue.read { database in
      #expect(!(try database.tableExists("dismissed_transfer_pair")))
    }
  }

  @Test("v13 drops the denormalised transfer_suggestion columns from transaction")
  func dropsDenormalisedTransactionColumns() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue)
    try queue.read { database in
      let cols = try Set(database.columns(in: "transaction").map(\.name))
      #expect(!cols.contains("transfer_suggestion_counterpart_id"))
      #expect(!cols.contains("transfer_suggestion_suggested_at"))
    }
  }

  @Test("suggestions lookup uses the tx indexes, not a scan")
  func suggestionLookupUsesIndex() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue)
    let txId = UUID()
    try queue.read { database in
      let plan = try Row.fetchAll(
        database,
        sql: """
          EXPLAIN QUERY PLAN
          SELECT * FROM transfer_suggestion
          WHERE transaction_id_a = ? OR transaction_id_b = ?
          """,
        arguments: [txId, txId]
      ).map { String(describing: $0["detail"] ?? "") }
      let indexUses = plan.filter { $0.contains("USING INDEX transfer_suggestion_by_tx_") }
      #expect(
        indexUses.count >= 2,
        "OR-of-two-indexed-columns must union both transfer_suggestion_by_tx_a and _b")
      #expect(!plan.contains { $0.contains("SCAN transfer_suggestion") })
    }
  }
}
