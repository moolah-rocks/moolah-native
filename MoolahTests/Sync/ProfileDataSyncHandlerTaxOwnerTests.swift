import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("ProfileDataSyncHandler — tax owner remote changes")
struct ProfileDataSyncHandlerTaxOwnerTests {
  @Test("stale remote echo cannot overwrite an explicit default owner rename")
  func staleRemoteEchoCannotOverwriteExplicitDefaultOwnerRename() async throws {
    let defaultOwnerId = UUID()
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerAndDatabase(
        defaultTaxOwnerId: defaultOwnerId)
    }
    let repository = harness.handler.grdbRepositories.taxOwners
    try repository.bootstrapImplicitDefaultOwner()
    _ = try await repository.update(TaxOwner(id: defaultOwnerId, name: "Adrian"))
    let stale = TaxOwnerRow(
      domain: TaxOwner(id: defaultOwnerId, name: "Default owner")
    ).toCKRecord(in: harness.handler.zoneID)

    let result = harness.handler.applyRemoteChanges(saved: [stale], deleted: [])

    guard case .success = result else {
      Issue.record("Expected .success but got \(result)")
      return
    }
    #expect(try await repository.fetchAll() == [TaxOwner(id: defaultOwnerId, name: "Adrian")])
    #expect(try repository.dirtyIdsSync(from: [defaultOwnerId]) == [defaultOwnerId])
  }

  @Test("remote default tax owner delete through handler records tombstone")
  func remoteDefaultTaxOwnerDeleteThroughHandlerRecordsTombstone() async throws {
    let defaultOwnerId = UUID()
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerAndDatabase(
        defaultTaxOwnerId: defaultOwnerId)
    }
    let handler = harness.handler
    let database = harness.database
    let owner = TaxOwner(id: defaultOwnerId, name: "Default owner")
    try await database.write { database in
      try TaxOwnerRow(domain: owner).insert(database)
    }

    let result = handler.applyRemoteChanges(
      saved: [],
      deleted: [deletedTaxOwnerRecordID(defaultOwnerId, zoneID: handler.zoneID)])

    guard case .success(let changedTypes) = result else {
      Issue.record("Expected .success but got \(result)")
      return
    }
    #expect(changedTypes.contains(TaxOwnerRow.recordType))
    let rows = try await database.read { database in
      try TaxOwnerRow.fetchAll(database)
    }
    let isTombstoned = try await database.read { database in
      try DeletionJournal.hasDataTombstone(
        recordName: TaxOwnerRow.recordName(for: defaultOwnerId),
        in: database)
    }
    #expect(rows.isEmpty)
    #expect(isTombstoned)
  }

  @Test("remote tax owner delete through handler cleans and requeues referencing records")
  func remoteTaxOwnerDeleteThroughHandlerCleansAndRequeuesReferences() async throws {
    let capture = ProfileDataSyncHookCapture()
    let harness = try await makeReferenceCleanupHarness(capture: capture)
    let ownerId = harness.seed.ownerId

    let result = harness.handler.applyRemoteChanges(
      saved: [],
      deleted: [deletedTaxOwnerRecordID(ownerId, zoneID: harness.handler.zoneID)])

    guard case .success(let changedTypes) = result else {
      Issue.record("Expected .success but got \(result)")
      return
    }
    #expect(changedTypes.contains(TaxOwnerRow.recordType))
    try await assertReferencesCleaned(in: harness.database, seed: harness.seed)
    #expect(capture.accountChanges.count == 1)
    #expect(capture.accountChanges.first?.recordType == AccountRow.recordType)
    #expect(capture.accountChanges.first?.id == harness.seed.accountId)
    #expect(capture.categoryChanges.count == 1)
    #expect(capture.categoryChanges.first?.recordType == CategoryRow.recordType)
    #expect(capture.categoryChanges.first?.id == harness.seed.categoryId)
  }

  @Test("a tax-owner deletion preserves a pending local edit and its references")
  func dirtyTaxOwnerSurvivesRemoteDeletion() async throws {
    let capture = ProfileDataSyncHookCapture()
    let harness = try await makeReferenceCleanupHarness(capture: capture)
    try await harness.database.write { database in
      try harness.handler.grdbRepositories.taxOwners.markNeedsPushSync(
        id: harness.seed.ownerId, in: database)
    }

    _ = harness.handler.applyRemoteChanges(
      saved: [],
      deleted: [
        deletedTaxOwnerRecordID(harness.seed.ownerId, zoneID: harness.handler.zoneID)
      ])

    let counts = try await harness.database.read { database in
      (
        try TaxOwnerRow.fetchOne(database, key: harness.seed.ownerId),
        try AccountTaxOwnerRow.fetchCount(database),
        try CategoryTaxOwnerRow.fetchCount(database)
      )
    }
    #expect(counts.0 != nil)
    #expect(counts.1 == 1)
    #expect(counts.2 == 1)
    #expect(capture.accountChanges.isEmpty)
    #expect(capture.categoryChanges.isEmpty)
  }

  private func makeReferenceCleanupHarness(
    capture: ProfileDataSyncHookCapture
  ) async throws -> TaxOwnerReferenceCleanupHarness {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerAndDatabase(
        onAccountChanged: capture.appendAccountChange(_:_:),
        onCategoryChanged: capture.appendCategoryChange(_:_:))
    }
    let seed = TaxOwnerReferenceSeed(ownerId: UUID(), accountId: UUID(), categoryId: UUID())
    try await seedTaxOwnerReferences(in: harness.database, seed: seed)
    return TaxOwnerReferenceCleanupHarness(
      handler: harness.handler,
      database: harness.database,
      seed: seed)
  }

  private func seedTaxOwnerReferences(
    in database: DatabaseQueue,
    seed: TaxOwnerReferenceSeed
  ) async throws {
    try await database.write { database in
      try TaxOwnerRow(domain: TaxOwner(id: seed.ownerId, name: "Trust")).insert(database)
      var account = ProfileDataSyncHandlerTestSupport.accountRow(
        id: seed.accountId, name: "Trust brokerage")
      account.taxOwnerIdsEncoded = TaxOwnerIDListCoding.encode([seed.ownerId])
      try account.insert(database)
      try GRDBTaxOwnershipPersistence.replaceAccountOwners(
        accountId: seed.accountId, ownerIds: [seed.ownerId], in: database)
      var category = ProfileDataSyncHandlerTestSupport.categoryRow(
        id: seed.categoryId, name: "Distribution")
      category.isTaxReportable = true
      category.taxOwnerIdsEncoded = TaxOwnerIDListCoding.encode([seed.ownerId])
      try category.insert(database)
      try GRDBTaxOwnershipPersistence.replaceCategoryOwners(
        categoryId: seed.categoryId, ownerIds: [seed.ownerId], in: database)
    }
  }

  private func assertReferencesCleaned(
    in database: DatabaseQueue,
    seed: TaxOwnerReferenceSeed
  ) async throws {
    try await database.read { database in
      #expect(try TaxOwnerRow.fetchCount(database) == 0)
      #expect(try AccountTaxOwnerRow.fetchCount(database) == 0)
      #expect(try CategoryTaxOwnerRow.fetchCount(database) == 0)
      let account = try #require(try AccountRow.fetchOne(database, key: seed.accountId))
      let category = try #require(try CategoryRow.fetchOne(database, key: seed.categoryId))
      let accountNeedsPush = try needsPushValue(
        table: "account", id: seed.accountId, database: database)
      let categoryNeedsPush = try needsPushValue(
        table: "category", id: seed.categoryId, database: database)
      #expect(TaxOwnerIDListCoding.decode(account.taxOwnerIdsEncoded).isEmpty)
      #expect(TaxOwnerIDListCoding.decode(category.taxOwnerIdsEncoded).isEmpty)
      #expect(accountNeedsPush == 1)
      #expect(categoryNeedsPush == 1)
    }
  }

  private func needsPushValue(table: String, id: UUID, database: Database) throws -> Int? {
    try Int.fetchOne(
      database,
      sql: "SELECT needs_push FROM \(table) WHERE id = ?",
      arguments: [id])
  }

  private func deletedTaxOwnerRecordID(
    _ id: UUID,
    zoneID: CKRecordZone.ID
  ) -> (CKRecord.ID, String) {
    let recordID = CKRecord.ID(
      recordType: TaxOwnerRow.recordType,
      uuid: id,
      zoneID: zoneID)
    return (recordID, TaxOwnerRow.recordType)
  }
}

private struct TaxOwnerReferenceCleanupHarness {
  let handler: ProfileDataSyncHandler
  let database: DatabaseQueue
  let seed: TaxOwnerReferenceSeed
}

private struct TaxOwnerReferenceSeed {
  let ownerId: UUID
  let accountId: UUID
  let categoryId: UUID
}

private final class ProfileDataSyncHookCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var _accountChanges: [(recordType: String, id: UUID)] = []
  private var _categoryChanges: [(recordType: String, id: UUID)] = []

  var accountChanges: [(recordType: String, id: UUID)] {
    lock.withLock { _accountChanges }
  }

  var categoryChanges: [(recordType: String, id: UUID)] {
    lock.withLock { _categoryChanges }
  }

  func appendAccountChange(_ recordType: String, _ id: UUID) {
    lock.withLock { _accountChanges.append((recordType, id)) }
  }

  func appendCategoryChange(_ recordType: String, _ id: UUID) {
    lock.withLock { _categoryChanges.append((recordType, id)) }
  }
}
