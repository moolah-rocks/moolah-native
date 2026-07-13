import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("Tax owner default persistence")
struct TaxOwnerDefaultPersistenceTests {
  @Test("backend bootstrap creates default tax owner row")
  func backendBootstrapCreatesDefaultTaxOwner() async throws {
    let database = try ProfileDatabase.openInMemory()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let profile = Profile(label: "Family")
    let backend = CloudKitBackend(
      database: database,
      instrument: profile.instrument,
      profileLabel: profile.label,
      defaultTaxOwnerId: profile.defaultTaxOwnerId,
      conversionService: FakeConversionService.fixedRates([:]),
      instrumentRegistry: registry)
    try backend.grdbTaxOwners.bootstrapImplicitDefaultOwner()

    let owners = try await backend.taxOwners.fetchAll()

    #expect(owners.map(\.id) == [profile.defaultTaxOwnerId])
    #expect(owners.first?.name == "Default owner")
    #expect(try backend.grdbTaxOwners.allRowIdsSync().isEmpty)
    #expect(try backend.grdbTaxOwners.unsyncedRowIdsSync().isEmpty)
  }

  @Test("bootstrapped default tax owner remains a clean local placeholder")
  func bootstrappedDefaultTaxOwnerRemainsCleanPlaceholder() async throws {
    let database = try ProfileDatabase.openInMemory()
    let ownerId = UUID()
    let recorder = TaxOwnerChangeRecorder()
    let repository = GRDBTaxOwnerRepository(
      database: database,
      defaultTaxOwnerId: ownerId,
      onRecordChanged: recorder.record(_:_:))
    try repository.bootstrapImplicitDefaultOwner()

    #expect(try await repository.fetchAll().map(\.id) == [ownerId])

    #expect(recorder.ids.isEmpty)
    #expect(try repository.allRowIdsSync().isEmpty)
    #expect(try repository.unsyncedRowIdsSync().isEmpty)
    #expect(try repository.fetchRowSync(id: ownerId) == nil)
  }

  @Test("failed bootstrap rolls back the placeholder write")
  func failedBootstrapRollsBackPlaceholderWrite() async throws {
    let database = try ProfileDatabase.openInMemory()
    let ownerId = UUID()
    let repository = GRDBTaxOwnerRepository(database: database, defaultTaxOwnerId: ownerId)
    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER seed_deletion_after_owner_insert
          AFTER INSERT ON tax_owner
          BEGIN
            INSERT INTO deletion_journal (zone_name, record_name, record_type, queued_at)
            VALUES ('@profile-data', NEW.record_name, 'TaxOwnerRecord', 0);
          END;

          CREATE TRIGGER fail_deletion_clear
          BEFORE DELETE ON deletion_journal
          WHEN OLD.zone_name = '@profile-data'
          BEGIN
            SELECT RAISE(ABORT, 'forced journal clear failure');
          END;
          """)
    }

    #expect(throws: DatabaseError.self) {
      try repository.bootstrapImplicitDefaultOwner()
    }

    let counts = try await database.read { database in
      (
        owners: try TaxOwnerRow.fetchCount(database),
        journal: try DeletionJournalRow.fetchCount(database)
      )
    }
    #expect(counts.owners == 0)
    #expect(counts.journal == 0)
  }

  @Test("downloaded renamed default owner replaces local placeholder")
  func downloadedRenamedDefaultOwnerReplacesLocalPlaceholder() async throws {
    let database = try ProfileDatabase.openInMemory()
    let ownerId = UUID()
    let repository = GRDBTaxOwnerRepository(database: database, defaultTaxOwnerId: ownerId)
    try repository.bootstrapImplicitDefaultOwner()
    var serverRow = TaxOwnerRow(domain: TaxOwner(id: ownerId, name: "Adrian"))
    serverRow.encodedSystemFields = Data([0x01])

    try repository.applyRemoteChangesSync(saved: [serverRow], deleted: [])

    #expect(try await repository.fetchAll() == [TaxOwner(id: ownerId, name: "Adrian")])
    #expect(try repository.allRowIdsSync() == [ownerId])
    #expect(try repository.unsyncedRowIdsSync().isEmpty)
  }

  @Test("renaming local placeholder converts it to explicit synced data")
  func renamingLocalPlaceholderConvertsItToExplicitData() async throws {
    let database = try ProfileDatabase.openInMemory()
    let ownerId = UUID()
    let recorder = TaxOwnerChangeRecorder()
    let repository = GRDBTaxOwnerRepository(
      database: database,
      defaultTaxOwnerId: ownerId,
      onRecordChanged: recorder.record(_:_:))
    try repository.bootstrapImplicitDefaultOwner()

    _ = try await repository.update(TaxOwner(id: ownerId, name: "Adrian"))

    #expect(recorder.ids == [ownerId])
    #expect(try repository.allRowIdsSync() == [ownerId])
    #expect(try repository.unsyncedRowIdsSync() == [ownerId])
    let row = try #require(try repository.fetchRowSync(id: ownerId))
    #expect(row.toCKRecord(in: CKRecordZone.ID(zoneName: "profile-test"))["name"] == "Adrian")
  }

  @Test("clearing system fields keeps explicit default owner syncable")
  func clearingSystemFieldsKeepsExplicitDefaultOwnerSyncable() async throws {
    let database = try ProfileDatabase.openInMemory()
    let ownerId = UUID()
    let repository = GRDBTaxOwnerRepository(database: database, defaultTaxOwnerId: ownerId)
    try repository.bootstrapImplicitDefaultOwner()
    _ = try await repository.update(TaxOwner(id: ownerId, name: "Adrian"))
    _ = try repository.clearNeedsPushBatchSync([ownerId])
    try repository.clearAllSystemFieldsSync()

    #expect(try repository.allRowIdsSync() == [ownerId])
    #expect(try repository.unsyncedRowIdsSync() == [ownerId])
  }

  @Test("explicit non-default owner remains syncable beside placeholder")
  func explicitNonDefaultOwnerRemainsSyncable() async throws {
    let database = try ProfileDatabase.openInMemory()
    let defaultOwnerId = UUID()
    let explicitOwner = TaxOwner(id: UUID(), name: "Family trust", kind: .trust)
    let repository = GRDBTaxOwnerRepository(
      database: database,
      defaultTaxOwnerId: defaultOwnerId)
    try repository.bootstrapImplicitDefaultOwner()

    _ = try await repository.create(explicitOwner)

    #expect(try Set(repository.allRowIdsSync()) == [explicitOwner.id])
    #expect(try Set(repository.unsyncedRowIdsSync()) == [explicitOwner.id])
  }

  @Test("fetching implicit default tax owner does not queue a save")
  func fetchingImplicitDefaultTaxOwnerDoesNotQueueSave() async throws {
    let database = try ProfileDatabase.openInMemory()
    let ownerId = UUID()
    let recorder = TaxOwnerChangeRecorder()
    let repository = GRDBTaxOwnerRepository(
      database: database,
      defaultTaxOwnerId: ownerId,
      onRecordChanged: recorder.record(_:_:))

    #expect(try await repository.fetchAll().map(\.id) == [ownerId])

    #expect(recorder.ids.isEmpty)
    #expect(try repository.allRowIdsSync().isEmpty)
    #expect(try repository.unsyncedRowIdsSync().isEmpty)
  }

  @Test("updated default tax owner is protected from recreation after delete")
  func updatedDefaultTaxOwnerIsProtectedFromRecreationAfterDelete() async throws {
    let database = try ProfileDatabase.openInMemory()
    let oldDefaultOwnerId = UUID()
    let newDefaultOwnerId = UUID()
    let repository = GRDBTaxOwnerRepository(
      database: database,
      defaultTaxOwnerId: oldDefaultOwnerId)
    try repository.bootstrapImplicitDefaultOwner()
    #expect(try await repository.fetchAll().map(\.id) == [oldDefaultOwnerId])
    _ = try await repository.create(TaxOwner(id: newDefaultOwnerId, name: "New default"))

    repository.updateDefaultTaxOwnerId(newDefaultOwnerId)
    try await repository.delete(id: newDefaultOwnerId)
    try await database.write { database in
      try DeletionJournal.clearDataDeletion(
        recordName: TaxOwnerRow.recordName(for: newDefaultOwnerId),
        in: database)
    }

    #expect(try await repository.fetchAll().map(\.id) == [oldDefaultOwnerId])
  }

  @Test("incoming server default tax owner is not left dirty")
  func incomingServerDefaultTaxOwnerIsNotLeftDirty() async throws {
    let database = try ProfileDatabase.openInMemory()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let profile = Profile(label: "Family")
    let backend = CloudKitBackend(
      database: database,
      instrument: profile.instrument,
      profileLabel: profile.label,
      defaultTaxOwnerId: profile.defaultTaxOwnerId,
      conversionService: FakeConversionService.fixedRates([:]),
      instrumentRegistry: registry)
    let serverOwner = TaxOwner(
      id: profile.defaultTaxOwnerId, name: "Server owner", kind: .trust)
    var serverRow = TaxOwnerRow(domain: serverOwner)
    serverRow.encodedSystemFields = Data([0x01])
    try backend.grdbTaxOwners.applyRemoteChangesSync(saved: [serverRow], deleted: [])

    let owners = try await backend.taxOwners.fetchAll()

    #expect(owners == [serverOwner])
    #expect(try backend.grdbTaxOwners.unsyncedRowIdsSync().isEmpty)
    #expect(try backend.grdbTaxOwners.dirtyIdsSync(from: [profile.defaultTaxOwnerId]).isEmpty)
  }

  @Test("incoming server default tax owner delete is tombstoned")
  func incomingServerDefaultTaxOwnerDeleteIsTombstoned() async throws {
    let database = try ProfileDatabase.openInMemory()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let profile = Profile(label: "Family")
    let backend = CloudKitBackend(
      database: database,
      instrument: profile.instrument,
      profileLabel: profile.label,
      defaultTaxOwnerId: profile.defaultTaxOwnerId,
      conversionService: FakeConversionService.fixedRates([:]),
      instrumentRegistry: registry)
    #expect(try await backend.taxOwners.fetchAll().map(\.id) == [profile.defaultTaxOwnerId])

    try backend.grdbTaxOwners.applyRemoteChangesSync(
      saved: [], deleted: [profile.defaultTaxOwnerId])

    #expect(try await backend.taxOwners.fetchAll().isEmpty)
    #expect(try backend.grdbTaxOwners.allRowIdsSync().isEmpty)
  }

  @Test("stale server default tax owner save does not clear tombstone")
  func staleServerDefaultTaxOwnerSaveDoesNotClearTombstone() async throws {
    let database = try ProfileDatabase.openInMemory()
    let ownerId = UUID()
    let repository = GRDBTaxOwnerRepository(database: database, defaultTaxOwnerId: ownerId)
    let zoneID = CKRecordZone.ID(zoneName: "profile-\(UUID().uuidString)")
    let tombstoneDate = Date(timeIntervalSince1970: 1_000)
    let olderDate = Date(timeIntervalSince1970: 900)
    let newerDate = Date(timeIntervalSince1970: 1_100)
    let recordName = TaxOwnerRow.recordName(for: ownerId)
    try await database.write { database in
      try DeletionJournal.recordDataTombstone(
        recordName: recordName,
        recordType: TaxOwnerRow.recordType,
        at: tombstoneDate,
        in: database)
    }

    var staleRow = TaxOwnerRow(domain: TaxOwner(id: ownerId, name: "Stale default"))
    staleRow.encodedSystemFields =
      staleRow.toCKRecord(in: zoneID)
      .withModificationDate(olderDate)
      .encodedSystemFields
    try repository.applyRemoteChangesSync(saved: [staleRow], deleted: [])

    let afterStaleSave = try await database.read { database in
      (
        owner: try TaxOwnerRow.fetchOne(database, key: ownerId),
        tombstoned: try DeletionJournal.hasDataTombstone(recordName: recordName, in: database)
      )
    }
    #expect(afterStaleSave.owner == nil)
    #expect(afterStaleSave.tombstoned)

    let newerOwner = TaxOwner(id: ownerId, name: "Newer default")
    var newerRow = TaxOwnerRow(domain: newerOwner)
    newerRow.encodedSystemFields =
      newerRow.toCKRecord(in: zoneID)
      .withModificationDate(newerDate)
      .encodedSystemFields
    try repository.applyRemoteChangesSync(saved: [newerRow], deleted: [])

    let afterNewerSave = try await database.read { database in
      (
        owner: try TaxOwnerRow.fetchOne(database, key: ownerId)?.toDomain(),
        tombstoned: try DeletionJournal.hasDataTombstone(recordName: recordName, in: database)
      )
    }
    #expect(afterNewerSave.owner == newerOwner)
    #expect(afterNewerSave.tombstoned == false)
  }
}
