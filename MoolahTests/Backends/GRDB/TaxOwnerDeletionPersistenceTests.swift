import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("Tax owner deletion persistence")
struct TaxOwnerDeletionPersistenceTests {
  @Test("deleting tax owner removes account and category references")
  func deletingTaxOwnerRemovesReferences() async throws {
    let fixture = try await makeTaxOwnerReferenceFixture(ownerName: "Spouse")

    try await fixture.taxOwners.delete(id: fixture.owner.id)

    let account = try #require(try await fixture.accounts.fetchAll().first)
    let category = try #require(try await fixture.categories.fetchAll().first)
    #expect(account.taxOwnerIds.isEmpty)
    #expect(category.taxOwnerIds.isEmpty)
    try await fixture.database.read { database in
      let accountJoinCount = try AccountTaxOwnerRow.fetchCount(database)
      let categoryJoinCount = try CategoryTaxOwnerRow.fetchCount(database)
      let accountEncoded = try String.fetchOne(
        database,
        sql: "SELECT tax_owner_ids_encoded FROM account LIMIT 1")
      let categoryEncoded = try String.fetchOne(
        database,
        sql: "SELECT tax_owner_ids_encoded FROM category LIMIT 1")
      #expect(accountJoinCount == 0)
      #expect(categoryJoinCount == 0)
      #expect(accountEncoded == nil)
      #expect(categoryEncoded == nil)
    }
  }

  @Test("failed tax owner delete preserves account and category references")
  func failedTaxOwnerDeletePreservesReferences() async throws {
    let fixture = try await makeTaxOwnerReferenceFixture(ownerName: "Spouse")
    try await fixture.database.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER fail_tax_owner_delete
          BEFORE DELETE ON tax_owner
          BEGIN
            SELECT RAISE(ABORT, 'forced tax owner delete failure');
          END
          """)
    }

    do {
      try await fixture.taxOwners.delete(id: fixture.owner.id)
      Issue.record("delete should fail after reference cleanup starts")
    } catch {
      // Expected: the trigger aborts the same transaction that clears references.
    }

    let account = try #require(try await fixture.accounts.fetchAll().first)
    let category = try #require(try await fixture.categories.fetchAll().first)
    #expect(account.taxOwnerIds == [fixture.owner.id])
    #expect(category.taxOwnerIds == [fixture.owner.id])
    #expect(try await fixture.taxOwners.fetchAll().map(\.id) == [fixture.owner.id])
  }

  @Test("remote tax owner delete removes account and category references")
  func remoteTaxOwnerDeleteRemovesReferences() async throws {
    let fixture = try await makeTaxOwnerReferenceFixture(ownerName: "Trust")

    try fixture.taxOwners.applyRemoteChangesSync(saved: [], deleted: [fixture.owner.id])

    let account = try #require(try await fixture.accounts.fetchAll().first)
    let category = try #require(try await fixture.categories.fetchAll().first)
    #expect(account.taxOwnerIds.isEmpty)
    #expect(category.taxOwnerIds.isEmpty)
    #expect(try fixture.accounts.dirtyIdsSync(from: [account.id]) == [account.id])
    #expect(try fixture.categories.dirtyIdsSync(from: [category.id]) == [category.id])
  }

  @Test("remote tax owner delete emits account and category hooks for cleaned references")
  func remoteTaxOwnerDeleteEmitsReferenceHooks() async throws {
    let accountRecorder = ReferenceChangeRecorder(expectedRecordType: AccountRow.recordType)
    let categoryRecorder = ReferenceChangeRecorder(expectedRecordType: CategoryRow.recordType)
    let fixture = try await makeTaxOwnerReferenceFixture(
      ownerName: "Trust",
      onAccountChanged: accountRecorder.record(_:_:),
      onCategoryChanged: categoryRecorder.record(_:_:))

    try fixture.taxOwners.applyRemoteChangesSync(saved: [], deleted: [fixture.owner.id])

    #expect(accountRecorder.ids == [fixture.account.id])
    #expect(categoryRecorder.ids == [fixture.category.id])
  }

  @Test("deleting a missing tax owner is a no-op for deletion hooks")
  func deletingMissingTaxOwnerDoesNotEmitDeleteHook() async throws {
    let database = try ProfileDatabase.openInMemory()
    let recorder = TaxOwnerChangeRecorder()
    let repository = GRDBTaxOwnerRepository(
      database: database,
      onRecordDeleted: recorder.record(_:_:))

    try await repository.delete(id: UUID())

    #expect(recorder.ids.isEmpty)
  }

  private func makeTaxOwnerReferenceFixture(
    ownerName: String,
    onAccountChanged: (@Sendable (String, UUID) -> Void)? = nil,
    onCategoryChanged: (@Sendable (String, UUID) -> Void)? = nil
  ) async throws -> TaxOwnerReferenceFixture {
    let database = try ProfileDatabase.openInMemory()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let owner = TaxOwner(name: ownerName)
    let accountHook = onAccountChanged ?? { _, _ in }
    let categoryHook = onCategoryChanged ?? { _, _ in }
    let taxOwners = GRDBTaxOwnerRepository(
      database: database,
      onAccountChanged: accountHook,
      onCategoryChanged: categoryHook)
    let accounts = GRDBAccountRepository(
      database: database,
      instrumentResolver: registry,
      instrumentRegistrar: registry)
    let categories = GRDBCategoryRepository(database: database)

    _ = try await taxOwners.create(owner)
    let account = try await accounts.create(
      Account(
        name: "\(ownerName) account",
        type: .investment,
        instrument: .AUD,
        taxOwnerIds: [owner.id]))
    let category = try await categories.create(
      Moolah.Category(
        name: "\(ownerName) category",
        isTaxReportable: true,
        taxOwnerIds: [owner.id]))

    return TaxOwnerReferenceFixture(
      database: database,
      taxOwners: taxOwners,
      accounts: accounts,
      categories: categories,
      owner: owner,
      account: account,
      category: category)
  }
}

private struct TaxOwnerReferenceFixture {
  let database: DatabaseQueue
  let taxOwners: GRDBTaxOwnerRepository
  let accounts: GRDBAccountRepository
  let categories: GRDBCategoryRepository
  let owner: TaxOwner
  let account: Account
  let category: Moolah.Category
}
