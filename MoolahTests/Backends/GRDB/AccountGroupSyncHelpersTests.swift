import Foundation
import GRDB
import Testing

@testable import Moolah

/// Direct tests for the sync helpers on `GRDBAccountGroupRepository` —
/// the methods the CKSyncEngine apply / upload paths call from a
/// non-MainActor context. Mirrors the shape of the per-record-type
/// sync helper tests for `GRDBTransferSuggestionRepository`.
@Suite("GRDBAccountGroupRepository sync helpers")
struct AccountGroupSyncHelpersTests {

  // MARK: - applyRemoteChangesSync (saved)

  @Test
  func applyRemoteChangesSavedUpsertsRow() async throws {
    let database = try ProfileDatabase.openInMemory()
    let repo = GRDBAccountGroupRepository(database: database)

    let group = AccountGroup(
      name: "Cross-device", bucket: .investments, instrument: .defaultTestInstrument)
    let row = AccountGroupRow(domain: group)
    try repo.applyRemoteChangesSync(saved: [row], deleted: [])

    let fetched = try await repo.fetchAll()
    #expect(fetched.contains { $0.id == row.id && $0.name == "Cross-device" })
  }

  // MARK: - applyRemoteChangesSync (deleted)

  @Test
  func applyRemoteChangesDeletedRemovesRow() async throws {
    let database = try ProfileDatabase.openInMemory()
    let repo = GRDBAccountGroupRepository(database: database)

    let created = try await repo.create(
      AccountGroup(
        name: "Ephemeral", bucket: .investments, instrument: .defaultTestInstrument)
    )
    try repo.applyRemoteChangesSync(saved: [], deleted: [created.id])

    let fetched = try await repo.fetchAll()
    #expect(!fetched.contains { $0.id == created.id })
  }

  // MARK: - In-transaction variant

  @Test
  func applyRemoteChangesInTransactionVariantSucceeds() async throws {
    let database = try ProfileDatabase.openInMemory()
    let repo = GRDBAccountGroupRepository(database: database)

    let row = AccountGroupRow(
      domain: AccountGroup(
        name: "Tx", bucket: .investments, instrument: .defaultTestInstrument)
    )
    try await database.write { database in
      try repo.applyRemoteChangesSync(saved: [row], deleted: [], in: database)
    }

    let fetched = try await repo.fetchAll()
    #expect(fetched.contains { $0.id == row.id })
  }

  // MARK: - setEncodedSystemFieldsSync (single)

  @Test
  func setEncodedSystemFieldsSyncPersistsBlob() async throws {
    let database = try ProfileDatabase.openInMemory()
    let repo = GRDBAccountGroupRepository(database: database)

    let created = try await repo.create(
      AccountGroup(
        name: "Stamped", bucket: .investments, instrument: .defaultTestInstrument)
    )

    let payload = Data([0x01, 0x02, 0x03])
    let updated = try repo.setEncodedSystemFieldsSync(id: created.id, data: payload)
    #expect(updated == true)

    let row = try await database.read { database in
      try AccountGroupRow
        .filter(AccountGroupRow.Columns.id == created.id)
        .fetchOne(database)
    }
    #expect(row?.encodedSystemFields == payload)
  }

  @Test
  func setEncodedSystemFieldsSyncReturnsFalseForUnknownId() throws {
    let database = try ProfileDatabase.openInMemory()
    let repo = GRDBAccountGroupRepository(database: database)

    let updated = try repo.setEncodedSystemFieldsSync(
      id: UUID(), data: Data([0xAA]))
    #expect(updated == false)
  }

  // MARK: - setEncodedSystemFieldsBatchSync

  @Test
  func setEncodedSystemFieldsBatchSyncUpdatesEveryRow() async throws {
    let database = try ProfileDatabase.openInMemory()
    let repo = GRDBAccountGroupRepository(database: database)

    let first = try await repo.create(
      AccountGroup(name: "A", bucket: .investments, instrument: .defaultTestInstrument)
    )
    let second = try await repo.create(
      AccountGroup(name: "B", bucket: .current, instrument: .defaultTestInstrument)
    )

    let payloadA = Data([0x01])
    let payloadB = Data([0x02])
    let updatedCount = try repo.setEncodedSystemFieldsBatchSync(
      [(id: first.id, data: payloadA), (id: second.id, data: payloadB)])
    #expect(updatedCount == 2)

    let rows = try await database.read { database in
      try AccountGroupRow.fetchAll(database)
    }
    let blobByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.encodedSystemFields) })
    #expect(blobByID[first.id] == payloadA)
    #expect(blobByID[second.id] == payloadB)
  }

  @Test
  func setEncodedSystemFieldsBatchSyncReturnsZeroForEmptyInput() throws {
    let database = try ProfileDatabase.openInMemory()
    let repo = GRDBAccountGroupRepository(database: database)

    let updatedCount = try repo.setEncodedSystemFieldsBatchSync([])
    #expect(updatedCount == 0)
  }

  // MARK: - clearAllSystemFieldsSync

  @Test
  func clearAllSystemFieldsSyncNullsEveryBlob() async throws {
    let database = try ProfileDatabase.openInMemory()
    let repo = GRDBAccountGroupRepository(database: database)

    let created = try await repo.create(
      AccountGroup(
        name: "Cleared", bucket: .investments, instrument: .defaultTestInstrument)
    )
    _ = try repo.setEncodedSystemFieldsSync(id: created.id, data: Data([0x99]))

    try repo.clearAllSystemFieldsSync()

    let row = try await database.read { database in
      try AccountGroupRow
        .filter(AccountGroupRow.Columns.id == created.id)
        .fetchOne(database)
    }
    #expect(row?.encodedSystemFields == nil)
  }

  // MARK: - deleteAllSync

  @Test
  func deleteAllSyncRemovesEveryRow() async throws {
    let database = try ProfileDatabase.openInMemory()
    let repo = GRDBAccountGroupRepository(database: database)

    _ = try await repo.create(
      AccountGroup(name: "A", bucket: .investments, instrument: .defaultTestInstrument)
    )
    _ = try await repo.create(
      AccountGroup(name: "B", bucket: .current, instrument: .defaultTestInstrument)
    )

    try repo.deleteAllSync()

    let fetched = try await repo.fetchAll()
    #expect(fetched.isEmpty)
  }

  // MARK: - allRowIdsSync / unsyncedRowIdsSync

  @Test
  func allRowIdsSyncReturnsEveryId() async throws {
    let database = try ProfileDatabase.openInMemory()
    let repo = GRDBAccountGroupRepository(database: database)

    let first = try await repo.create(
      AccountGroup(name: "A", bucket: .investments, instrument: .defaultTestInstrument)
    )
    let second = try await repo.create(
      AccountGroup(name: "B", bucket: .current, instrument: .defaultTestInstrument)
    )

    let ids = Set(try repo.allRowIdsSync())
    #expect(ids == Set([first.id, second.id]))
  }

  @Test
  func unsyncedRowIdsSyncReturnsRowsWithoutSystemFields() async throws {
    let database = try ProfileDatabase.openInMemory()
    let repo = GRDBAccountGroupRepository(database: database)

    let unsynced = try await repo.create(
      AccountGroup(
        name: "Pending", bucket: .investments, instrument: .defaultTestInstrument)
    )
    let synced = try await repo.create(
      AccountGroup(name: "Synced", bucket: .current, instrument: .defaultTestInstrument)
    )
    _ = try repo.setEncodedSystemFieldsSync(id: synced.id, data: Data([0xAB]))

    let ids = try repo.unsyncedRowIdsSync()
    #expect(ids.contains(unsynced.id))
    #expect(!ids.contains(synced.id))
  }

  // MARK: - fetchRowSync / fetchRowsSync

  @Test
  func fetchRowSyncReturnsRowOrNil() async throws {
    let database = try ProfileDatabase.openInMemory()
    let repo = GRDBAccountGroupRepository(database: database)

    let created = try await repo.create(
      AccountGroup(name: "X", bucket: .investments, instrument: .defaultTestInstrument)
    )

    let found = try repo.fetchRowSync(id: created.id)
    #expect(found?.id == created.id)

    let missing = try repo.fetchRowSync(id: UUID())
    #expect(missing == nil)
  }

  @Test
  func fetchRowsSyncReturnsMatchingSubset() async throws {
    let database = try ProfileDatabase.openInMemory()
    let repo = GRDBAccountGroupRepository(database: database)

    let first = try await repo.create(
      AccountGroup(name: "A", bucket: .investments, instrument: .defaultTestInstrument)
    )
    let second = try await repo.create(
      AccountGroup(name: "B", bucket: .current, instrument: .defaultTestInstrument)
    )
    _ = try await repo.create(
      AccountGroup(name: "C", bucket: .investments, instrument: .defaultTestInstrument)
    )

    let rows = try repo.fetchRowsSync(ids: [first.id, second.id])
    let ids = Set(rows.map(\.id))
    #expect(ids == Set([first.id, second.id]))
  }
}
