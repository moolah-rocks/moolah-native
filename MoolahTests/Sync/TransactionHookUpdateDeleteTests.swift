import Foundation
import GRDB
import Testing

@testable import Moolah

/// Pins the per-leg multi-type hook contract for `GRDBTransactionRepository`
/// `update(_:)` and `delete(id:)`. The header tests for `create(_:)` live
/// in `RepositoryHookRecordTypeTests`.
///
/// A regression that hard-coded `TransactionRow.recordType` on the leg
/// emits in `update` / `delete` would upload leg records under the wrong
/// recordName and phantom-delete on every other device.
@Suite("Transaction hooks emit per-leg record types on update/delete")
@MainActor
struct TransactionHookUpdateDeleteTests {

  /// Confined to `@MainActor` so the (non-Sendable) closures wired to the
  /// repository can append into the buffers without crossing actors.
  @MainActor
  final class HookCapture {
    var changed: [(recordType: String, id: UUID)] = []
    var deleted: [(recordType: String, id: UUID)] = []
  }

  private func makeChangedHook(
    _ capture: HookCapture
  ) -> @Sendable (String, UUID) -> Void {
    { recordType, id in
      Task { @MainActor in
        capture.changed.append((recordType, id))
      }
    }
  }

  private func makeDeletedHook(
    _ capture: HookCapture
  ) -> @Sendable (String, UUID) -> Void {
    { recordType, id in
      Task { @MainActor in
        capture.deleted.append((recordType, id))
      }
    }
  }

  private func drainHookHops() async throws {
    try await Task.sleep(for: .milliseconds(50))
  }

  @Test(
    "update(_:) preserving leg ids emits TransactionRow change + per-leg upserts, no deletes")
  func transactionUpdateEmitsLegRecordType() async throws {
    let database = try ProfileDatabase.openInMemory()
    let capture = HookCapture()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let txnRepo = GRDBTransactionRepository(
      database: database,
      defaultInstrument: .defaultTestInstrument,
      conversionService: FixedConversionService(),
      instrumentResolver: registry,
      instrumentRegistrar: registry,
      onRecordChanged: makeChangedHook(capture),
      onRecordDeleted: makeDeletedHook(capture))

    let accountId = UUID()
    let txn = try await txnRepo.create(
      Transaction(
        date: Date(), payee: "Trade",
        legs: [
          makeContractTestLeg(accountId: accountId, quantity: -100, type: .transfer),
          makeContractTestLeg(accountId: accountId, quantity: 100, type: .transfer),
        ]))
    try await drainHookHops()
    capture.changed.removeAll()
    capture.deleted.removeAll()

    // Update with the same legs (preserving ids) but a different payee.
    // Expected hook fan-out: 1 TransactionRow change, N TransactionLegRow
    // changes (one upsert per leg), 0 TransactionLegRow deletes.
    var updated = txn
    updated.payee = "Renamed Trade"
    _ = try await txnRepo.update(updated)
    try await drainHookHops()

    let txnEmits = capture.changed.filter { $0.recordType == TransactionRow.recordType }
    #expect(txnEmits.map(\.id) == [txn.id])
    let legChanges = capture.changed.filter { $0.recordType == TransactionLegRow.recordType }
    // Identity check: the upsert must emit the *original* leg ids — not
    // freshly-allocated ones. A regression that reintroduces fresh-UUID
    // allocation in performUpdate would still emit two leg-changes
    // (passing a count-only assertion) while churning the recordName.
    let emittedLegIds = Set(legChanges.map(\.id))
    let originalLegIds = Set(txn.legs.map(\.id))
    #expect(emittedLegIds == originalLegIds)
    // Crucially: no leg-delete events when the leg array is preserved by id.
    let legDeletes = capture.deleted.filter { $0.recordType == TransactionLegRow.recordType }
    #expect(legDeletes.isEmpty)
    let txnDeletes = capture.deleted.filter { $0.recordType == TransactionRow.recordType }
    #expect(txnDeletes.isEmpty)
  }

  @Test(
    "update(_:) replacing legs (different ids) emits per-leg upserts + per-leg deletes")
  func transactionUpdateWithReplacedLegsEmitsDeletes() async throws {
    let database = try ProfileDatabase.openInMemory()
    let capture = HookCapture()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let txnRepo = GRDBTransactionRepository(
      database: database,
      defaultInstrument: .defaultTestInstrument,
      conversionService: FixedConversionService(),
      instrumentResolver: registry,
      instrumentRegistrar: registry,
      onRecordChanged: makeChangedHook(capture),
      onRecordDeleted: makeDeletedHook(capture))

    let accountId = UUID()
    let txn = try await txnRepo.create(
      Transaction(
        date: Date(), payee: "Trade",
        legs: [
          makeContractTestLeg(accountId: accountId, quantity: -100, type: .transfer),
          makeContractTestLeg(accountId: accountId, quantity: 100, type: .transfer),
        ]))
    try await drainHookHops()
    capture.changed.removeAll()
    capture.deleted.removeAll()

    // Replace the leg array entirely — every leg has a fresh id.
    // Expected: 2 leg-upserts (the new ids) + 2 leg-deletes (the old ids).
    let replacement = Transaction(
      id: txn.id, date: txn.date, payee: txn.payee,
      legs: [
        makeContractTestLeg(accountId: accountId, quantity: -50, type: .transfer),
        makeContractTestLeg(accountId: accountId, quantity: 50, type: .transfer),
      ])
    _ = try await txnRepo.update(replacement)
    try await drainHookHops()

    let legChanges = capture.changed.filter { $0.recordType == TransactionLegRow.recordType }
    // Identity check on the upsert side: emitted ids match the *replacement*
    // legs, not the originals.
    let replacementIds = Set(replacement.legs.map(\.id))
    let changedIds = Set(legChanges.map(\.id))
    #expect(changedIds == replacementIds)
    let legDeletes = capture.deleted.filter { $0.recordType == TransactionLegRow.recordType }
    // The deleted ids are the original legs', not the replacement's.
    let originalIds = Set(txn.legs.map(\.id))
    let deletedIds = Set(legDeletes.map(\.id))
    #expect(deletedIds == originalIds)
  }

  @Test("replace reusing ids suppresses their deletes; only the removed leg is deleted")
  func transactionReplaceReusingIdsSuppressesDeletes() async throws {
    let database = try ProfileDatabase.openInMemory()
    let capture = HookCapture()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let txnRepo = GRDBTransactionRepository(
      database: database,
      defaultInstrument: .defaultTestInstrument,
      conversionService: FixedConversionService(),
      instrumentResolver: registry,
      instrumentRegistrar: registry,
      onRecordChanged: makeChangedHook(capture),
      onRecordDeleted: makeDeletedHook(capture))

    let accountId = UUID()
    let txn = try await txnRepo.create(
      Transaction(
        date: Date(), payee: "Trade",
        legs: [
          makeContractTestLeg(accountId: accountId, quantity: -100, type: .transfer),
          makeContractTestLeg(accountId: accountId, quantity: 100, type: .transfer),
        ]))
    try await drainHookHops()
    capture.changed.removeAll()
    capture.deleted.removeAll()

    // Rewrite under the SAME header id, reusing leg[0]'s id verbatim, dropping
    // leg[1] (genuinely removed), and adding one fresh leg. Models a same-id
    // rewrite through `replace`.
    let freshLeg = makeContractTestLeg(accountId: accountId, quantity: 50, type: .transfer)
    let rebuilt = Transaction(
      id: txn.id, date: txn.date, payee: "Rewritten",
      legs: [txn.legs[0], freshLeg])
    _ = try await txnRepo.replace(deletingIds: [txn.id], creating: [rebuilt])
    try await drainHookHops()

    // Header id is reused → change, never delete.
    let txnChanges = capture.changed.filter { $0.recordType == TransactionRow.recordType }
    #expect(txnChanges.map(\.id) == [txn.id])
    let txnDeletes = capture.deleted.filter { $0.recordType == TransactionRow.recordType }
    #expect(txnDeletes.isEmpty)

    // Reused leg[0] + fresh leg → changes; the reused leg is NOT deleted.
    let legChanges = Set(
      capture.changed.filter { $0.recordType == TransactionLegRow.recordType }.map(\.id))
    #expect(legChanges == Set([txn.legs[0].id, freshLeg.id]))
    // Only the genuinely-removed leg[1] fans out a delete.
    let legDeletes = Set(
      capture.deleted.filter { $0.recordType == TransactionLegRow.recordType }.map(\.id))
    #expect(legDeletes == Set([txn.legs[1].id]))
  }

  @Test("delete(id:) emits TransactionRecord delete plus per-leg LegRecord deletes")
  func transactionDeleteEmitsLegRecordType() async throws {
    let database = try ProfileDatabase.openInMemory()
    let capture = HookCapture()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let txnRepo = GRDBTransactionRepository(
      database: database,
      defaultInstrument: .defaultTestInstrument,
      conversionService: FixedConversionService(),
      instrumentResolver: registry,
      instrumentRegistrar: registry,
      onRecordChanged: makeChangedHook(capture),
      onRecordDeleted: makeDeletedHook(capture))

    let accountId = UUID()
    let txn = try await txnRepo.create(
      Transaction(
        date: Date(), payee: "Trade",
        legs: [
          makeContractTestLeg(accountId: accountId, quantity: -100, type: .transfer),
          makeContractTestLeg(accountId: accountId, quantity: 100, type: .transfer),
        ]))
    try await drainHookHops()
    capture.changed.removeAll()
    capture.deleted.removeAll()

    try await txnRepo.delete(id: txn.id)
    try await drainHookHops()

    let txnDeletes = capture.deleted.filter { $0.recordType == TransactionRow.recordType }
    #expect(txnDeletes.map(\.id) == [txn.id])
    let legDeletes = capture.deleted.filter { $0.recordType == TransactionLegRow.recordType }
    // Two legs created → two leg-deletes emitted. A regression that
    // hard-coded `TransactionRow.recordType` on leg emits would drop
    // these to zero (and uploads would phantom-delete on other devices).
    #expect(legDeletes.count == 2)
    #expect(capture.changed.isEmpty)
  }
}
