import GRDB
import Testing

@testable import Moolah

@Suite("v30 transaction import-origin index migration")
struct ImportOriginIndexMigrationTests {
  @Test("migration adds the Recently Added filter index")
  func migrationAddsIndex() throws {
    let database = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(database, upTo: "v29_sync_mutation_token")

    let absentBeforeMigration = try database.read { database in
      try database.indexes(on: "transaction").allSatisfy {
        $0.name != "transaction_by_import_origin"
      }
    }
    #expect(absentBeforeMigration)

    try ProfileSchema.migrator.migrate(database)

    let indexedColumns = try database.read { database in
      try database.indexes(on: "transaction")
        .first { $0.name == "transaction_by_import_origin" }?
        .columns
    }
    #expect(indexedColumns == ["import_origin_kind", "import_origin_imported_at"])
  }
}
