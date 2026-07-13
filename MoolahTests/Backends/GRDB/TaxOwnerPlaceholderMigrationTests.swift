import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("v26_tax_owner_placeholder migration")
struct TaxOwnerPlaceholderMigrationTests {
  @Test("bootstrap preserves a migrated explicit default owner")
  func bootstrapPreservesMigratedExplicitDefaultOwner() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue, upTo: "v25_retire_investment_value_persistence")
    let ownerId = UUID()
    try queue.write { database in
      try database.execute(
        sql: """
          INSERT INTO tax_owner (id, record_name, name, kind, needs_push)
          VALUES (?, ?, 'Adrian', 'individual', 0)
          """,
        arguments: [ownerId, TaxOwnerRow.recordName(for: ownerId)])
    }

    try ProfileSchema.migrator.migrate(queue)

    try queue.read { database in
      let marker = try Bool.fetchOne(
        database,
        sql: "SELECT is_implicit_placeholder FROM tax_owner WHERE id = ?",
        arguments: [ownerId])
      #expect(marker == nil)
    }

    let repository = GRDBTaxOwnerRepository(database: queue, defaultTaxOwnerId: ownerId)
    try repository.bootstrapImplicitDefaultOwner()

    try queue.read { database in
      let marker = try Bool.fetchOne(
        database,
        sql: "SELECT is_implicit_placeholder FROM tax_owner WHERE id = ?",
        arguments: [ownerId])
      #expect(marker == false)
    }
    #expect(throws: DatabaseError.self) {
      try queue.write { database in
        try database.execute(
          sql: "UPDATE tax_owner SET is_implicit_placeholder = 2 WHERE id = ?",
          arguments: [ownerId])
      }
    }
  }

  @Test("bootstrap retires a migrated dirty generated default owner")
  func bootstrapRetiresMigratedDirtyGeneratedDefaultOwner() async throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue, upTo: "v25_retire_investment_value_persistence")
    let ownerId = UUID()
    try await queue.write { database in
      try database.execute(
        sql: """
          INSERT INTO tax_owner
            (id, record_name, name, kind, encoded_system_fields, needs_push)
          VALUES (?, ?, 'Default owner', 'individual', ?, 1)
          """,
        arguments: [ownerId, TaxOwnerRow.recordName(for: ownerId), Data([0x01])])
    }
    try ProfileSchema.migrator.migrate(queue)
    let sharedRegistry = try SharedRegistryTestSupport.makeSharedRegistry()
    let bundle = try ProfileGRDBRepositories.makeForApply(
      database: queue,
      sharedRegistry: sharedRegistry,
      defaultTaxOwnerId: ownerId,
      implicitDefaultTaxOwnerId: ownerId)
    let repository = bundle.taxOwners

    #expect(try await repository.fetchAll() == [TaxOwner(id: ownerId, name: "Default owner")])
    #expect(try repository.allRowIdsSync().isEmpty)
    #expect(try repository.unsyncedRowIdsSync().isEmpty)
    #expect(try repository.dirtyIdsSync(from: [ownerId]).isEmpty)
    #expect(try repository.fetchRowSync(id: ownerId) == nil)

    var serverRow = TaxOwnerRow(domain: TaxOwner(id: ownerId, name: "Adrian"))
    serverRow.encodedSystemFields = Data([0x01])
    try repository.applyRemoteChangesSync(saved: [serverRow], deleted: [])

    #expect(try await repository.fetchAll() == [TaxOwner(id: ownerId, name: "Adrian")])
    #expect(try repository.allRowIdsSync() == [ownerId])
  }
}
