// MoolahTests/Backends/GRDB/GRDBWalletSyncCheckpointRepositoryTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("GRDBWalletSyncCheckpointRepository")
struct GRDBWalletSyncCheckpointRepositoryTests {
  private func makeQueue() throws -> DatabaseQueue {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue)
    return queue
  }

  @Test
  func saveAndLoadRoundTrips() async throws {
    let queue = try makeQueue()
    let repo = GRDBWalletSyncCheckpointRepository(database: queue)
    let checkpoint = WalletSyncCheckpoint(id: UUID(), lastSyncedBlockNumber: 19_500_000)
    try await repo.save(checkpoint)
    let loaded = try await repo.load(accountId: checkpoint.id)
    #expect(loaded == checkpoint)
  }

  // Mirrors GRDBWalletSyncStateRepositoryTests.deleteIsIdempotent — deleting
  // an account that was already deleted (or never had a checkpoint) must be
  // a no-op, not throw. Absorbs the account-deletion / in-flight-sync race.
  @Test
  func deleteIsIdempotent() async throws {
    let queue = try makeQueue()
    let repo = GRDBWalletSyncCheckpointRepository(database: queue)
    let id = UUID()
    try await repo.delete(accountId: id)
    try await repo.delete(accountId: id)
    #expect(try await repo.load(accountId: id) == nil)
  }

  @Test("raiseToMax on a brand-new account writes blockNumber and fires onRecordChanged")
  func raiseToMaxWritesNewRow() async throws {
    let queue = try makeQueue()
    let changed = ChangeRecorder()
    let repo = GRDBWalletSyncCheckpointRepository(
      database: queue,
      onRecordChanged: { type, id in changed.record(type: type, id: id) })
    let id = UUID()

    try await repo.raiseToMax(accountId: id, blockNumber: 1000)

    let loaded = try await repo.load(accountId: id)
    #expect(loaded?.lastSyncedBlockNumber == 1000)
    #expect(changed.ids == [id])
  }

  @Test("raiseToMax never lowers an existing higher value and skips the change hook")
  func raiseToMaxNeverLowers() async throws {
    let queue = try makeQueue()
    let changed = ChangeRecorder()
    let repo = GRDBWalletSyncCheckpointRepository(
      database: queue,
      onRecordChanged: { type, id in changed.record(type: type, id: id) })
    let id = UUID()
    try await repo.raiseToMax(accountId: id, blockNumber: 2000)
    changed.reset()

    // A trailing head must not lower the stored value, and must not queue a
    // redundant CloudKit push for an inactive account.
    try await repo.raiseToMax(accountId: id, blockNumber: 1500)

    let loaded = try await repo.load(accountId: id)
    #expect(loaded?.lastSyncedBlockNumber == 2000)
    #expect(changed.ids.isEmpty)
  }

  @Test("raiseToMax raises an existing lower value and fires the change hook")
  func raiseToMaxRaisesExisting() async throws {
    let queue = try makeQueue()
    let changed = ChangeRecorder()
    let repo = GRDBWalletSyncCheckpointRepository(
      database: queue,
      onRecordChanged: { type, id in changed.record(type: type, id: id) })
    let id = UUID()
    try await repo.raiseToMax(accountId: id, blockNumber: 2000)
    changed.reset()

    try await repo.raiseToMax(accountId: id, blockNumber: 2500)

    let loaded = try await repo.load(accountId: id)
    #expect(loaded?.lastSyncedBlockNumber == 2500)
    #expect(changed.ids == [id])
  }

  /// Thread-safe recorder for `onRecordChanged` calls — the closure is
  /// `@Sendable` and may be invoked off the calling task.
  private final class ChangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedIds: [UUID] = []

    var ids: [UUID] { lock.withLock { recordedIds } }

    func record(type: String, id: UUID) {
      lock.withLock { recordedIds.append(id) }
    }

    func reset() {
      lock.withLock { recordedIds.removeAll() }
    }
  }
}
