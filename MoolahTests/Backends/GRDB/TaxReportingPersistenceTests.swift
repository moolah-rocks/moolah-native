// MoolahTests/Backends/GRDB/TaxReportingPersistenceTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

// These persistence scenarios share one database fixture surface; keeping them together preserves migration context.
@Suite("Tax reporting persistence")
struct TaxReportingPersistenceTests {
  @Test("profile schema creates tax reporting tables and columns")
  func profileSchemaCreatesTaxReportingStorage() throws {
    let database = try ProfileDatabase.openInMemory()
    try database.read { database in
      #expect(try database.tableExists("tax_owner"))
      #expect(try database.tableExists("account_tax_owner"))
      #expect(try database.tableExists("category_tax_owner"))

      let categoryColumns = try database.columns(in: "category").map(\.name)
      #expect(categoryColumns.contains("is_tax_reportable"))
      #expect(categoryColumns.contains("tax_owner_ids_encoded"))

      let accountColumns = try database.columns(in: "account").map(\.name)
      #expect(accountColumns.contains("tax_owner_ids_encoded"))

      let taxOwnerSchema = try #require(
        try String.fetchOne(
          database,
          sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'tax_owner'"))
      let accountOwnerSchema = try #require(
        try String.fetchOne(
          database,
          sql: """
            SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'account_tax_owner'
            """))
      let categoryOwnerSchema = try #require(
        try String.fetchOne(
          database,
          sql: """
            SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'category_tax_owner'
            """))
      #expect(!taxOwnerSchema.uppercased().contains("WITHOUT ROWID"))
      #expect(accountOwnerSchema.uppercased().contains("WITHOUT ROWID"))
      #expect(categoryOwnerSchema.uppercased().contains("WITHOUT ROWID"))
    }
  }

  @Test("profile index schema stores default tax owner id")
  func profileIndexSchemaStoresDefaultTaxOwnerId() throws {
    let database = try ProfileIndexDatabase.openInMemory()
    try database.read { database in
      let columns = try database.columns(in: "profile").map(\.name)
      #expect(columns.contains("default_tax_owner_id"))
    }
  }

  @Test("default tax owner migration uses the frozen deterministic id")
  func defaultTaxOwnerMigrationUsesFrozenDeterministicId() async throws {
    let profileId = try #require(UUID(uuidString: "12345678-1234-1234-1234-123456789ABC"))
    let expectedOwnerId = try #require(UUID(uuidString: "3BA7919D-9658-4269-9A7A-85806FA065D0"))
    let database = try DatabaseQueue()
    try ProfileIndexSchema.migrator.migrate(
      database, upTo: "v10_drop_cryptocompare_symbol")
    try await database.write { database in
      try database.execute(
        sql: """
          INSERT INTO profile (
            id, record_name, label, currency_code, financial_year_start_month, created_at
          ) VALUES (?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          profileId, ProfileRow.recordName(for: profileId), "Migrated", "AUD", 7,
          "2026-07-01T00:00:00Z",
        ])
    }
    try ProfileIndexSchema.migrator.migrate(database)

    let storedOwnerId = try await database.read { database in
      try UUID.fetchOne(
        database, sql: "SELECT default_tax_owner_id FROM profile WHERE id = ?",
        arguments: [profileId])
    }
    #expect(storedOwnerId == expectedOwnerId)
    #expect(storedOwnerId == TaxOwner.defaultOwnerId(for: profileId))
  }

  @Test("tax owner repository round-trips owners")
  func taxOwnerRepositoryRoundTripsOwners() async throws {
    let database = try ProfileDatabase.openInMemory()
    let repository = GRDBTaxOwnerRepository(database: database)
    let owner = TaxOwner(id: UUID(), name: "Family Trust", kind: .trust)

    _ = try await repository.create(owner)
    let fetched = try #require(try await repository.fetchAll().first)
    #expect(fetched == owner)

    let updated = TaxOwner(id: owner.id, name: "Discretionary Trust", kind: .trust)
    _ = try await repository.update(updated)
    let refetched = try #require(try await repository.fetchAll().first)
    #expect(refetched == updated)

    try await repository.delete(id: owner.id)
    #expect(try await repository.fetchAll().isEmpty)
  }

  @Test("account repository round-trips tax owner ids through join rows")
  func accountRepositoryRoundTripsTaxOwnerIds() async throws {
    let database = try ProfileDatabase.openInMemory()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let repository = GRDBAccountRepository(
      database: database,
      instrumentResolver: registry,
      instrumentRegistrar: registry)
    let ownerA = UUID()
    let ownerB = UUID()
    let account = Account(
      id: UUID(),
      name: "Joint",
      type: .bank,
      instrument: .defaultTestInstrument,
      position: 0,
      taxOwnerIds: [ownerA, ownerB])

    _ = try await repository.create(account)
    let fetched = try await repository.fetchAll()
    #expect(fetched.first?.taxOwnerIds == [ownerA, ownerB])

    var updated = try #require(fetched.first)
    updated.taxOwnerIds = [ownerB]
    _ = try await repository.update(updated)
    let refetched = try await repository.fetchAll()
    #expect(refetched.first?.taxOwnerIds == [ownerB])
  }

  @Test("category repository round-trips tax treatment and owners")
  func categoryRepositoryRoundTripsTaxFields() async throws {
    let database = try ProfileDatabase.openInMemory()
    let repository = GRDBCategoryRepository(database: database)
    let owner = UUID()
    let category = Moolah.Category(
      id: UUID(),
      name: "Interest",
      isTaxReportable: true,
      taxOwnerIds: [owner])

    _ = try await repository.create(category)
    let fetched = try #require(try await repository.fetchAll().first)
    #expect(fetched.isTaxReportable)
    #expect(fetched.taxOwnerIds == [owner])

    var updated = fetched
    updated.isTaxReportable = false
    updated.taxOwnerIds = []
    _ = try await repository.update(updated)
    let refetched = try #require(try await repository.fetchAll().first)
    #expect(!refetched.isTaxReportable)
    #expect(refetched.taxOwnerIds.isEmpty)
  }

  @Test("failed account owner replacement rolls back row and join changes")
  func failedAccountOwnerReplacementRollsBackRowsAndJoins() async throws {
    let database = try ProfileDatabase.openInMemory()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let originalOwner = UUID()
    let replacementOwner = UUID()
    let accounts = GRDBAccountRepository(
      database: database,
      instrumentResolver: registry,
      instrumentRegistrar: registry)
    let account = try await accounts.create(
      Account(
        name: "Joint",
        type: .bank,
        instrument: .AUD,
        taxOwnerIds: [originalOwner]))
    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER fail_account_tax_owner_insert
          BEFORE INSERT ON account_tax_owner
          BEGIN
            SELECT RAISE(ABORT, 'forced account owner replacement failure');
          END
          """)
    }

    var updated = account
    updated.name = "Joint updated"
    updated.taxOwnerIds = [replacementOwner]
    do {
      _ = try await accounts.update(updated)
      Issue.record("account update should fail after owner join rows are deleted")
    } catch {
      // Expected: the trigger aborts the transaction after replacement starts.
    }

    let refetched = try #require(try await accounts.fetchAll().first)
    #expect(refetched.name == "Joint")
    #expect(refetched.taxOwnerIds == [originalOwner])
    try await database.read { database in
      let rows = try AccountTaxOwnerRow.fetchAll(database)
      #expect(rows.map(\.ownerId) == [originalOwner])
    }
  }

  @Test("failed category owner replacement rolls back row and join changes")
  func failedCategoryOwnerReplacementRollsBackRowsAndJoins() async throws {
    let database = try ProfileDatabase.openInMemory()
    let originalOwner = UUID()
    let replacementOwner = UUID()
    let categories = GRDBCategoryRepository(database: database)
    let category = try await categories.create(
      Moolah.Category(
        name: "Interest",
        isTaxReportable: true,
        taxOwnerIds: [originalOwner]))
    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER fail_category_tax_owner_insert
          BEFORE INSERT ON category_tax_owner
          BEGIN
            SELECT RAISE(ABORT, 'forced category owner replacement failure');
          END
          """)
    }

    var updated = category
    updated.name = "Interest updated"
    updated.isTaxReportable = false
    updated.taxOwnerIds = [replacementOwner]
    do {
      _ = try await categories.update(updated)
      Issue.record("category update should fail after owner join rows are deleted")
    } catch {
      // Expected: the trigger aborts the transaction after replacement starts.
    }

    let refetched = try #require(try await categories.fetchAll().first)
    #expect(refetched.name == "Interest")
    #expect(refetched.isTaxReportable)
    #expect(refetched.taxOwnerIds == [originalOwner])
    try await database.read { database in
      let rows = try CategoryTaxOwnerRow.fetchAll(database)
      #expect(rows.map(\.ownerId) == [originalOwner])
    }
  }

}
