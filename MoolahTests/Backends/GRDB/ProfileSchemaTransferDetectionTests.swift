// MoolahTests/Backends/GRDB/ProfileSchemaTransferDetectionTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("ProfileSchema v12 transfer detection")
struct ProfileSchemaTransferDetectionTests {
  @Test("adds import_origin columns to transaction")
  func migrates() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue)
    try queue.read { database in
      let txColumns = try Set(database.columns(in: "transaction").map(\.name))
      for column in [
        "import_origin_kind",
        "import_origin_incoming_raw_description", "import_origin_incoming_bank_reference",
        "import_origin_incoming_raw_amount", "import_origin_incoming_raw_balance",
        "import_origin_incoming_imported_at", "import_origin_incoming_import_session_id",
        "import_origin_incoming_source_filename", "import_origin_incoming_parser_identifier",
      ] { #expect(txColumns.contains(column)) }
      // v13 dropped the denormalised transfer-suggestion columns
      #expect(!txColumns.contains("transfer_suggestion_counterpart_id"))
      #expect(!txColumns.contains("transfer_suggestion_suggested_at"))
      // v13 dropped dismissed_transfer_pair in favour of transfer_suggestion
      #expect(!(try database.tableExists("dismissed_transfer_pair")))
    }
  }
}
