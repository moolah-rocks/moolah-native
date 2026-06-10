@preconcurrency import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Focused unit tests for the clean-path modification-date gate (issue
/// #1085) on the per-profile-data handler, exercised through the real
/// `applyRemoteChanges` entry point with `TransactionLeg` rows. Covers the
/// gate decisions (reject older / reject tie / cached-date-advances), the
/// regression-lock that the gate did NOT replace the dirty-path guard, and
/// the §5f UUID-keyed within-batch dedup-to-max.
@Suite("clean-path modification-date gate (issue #1085)")
struct ModificationDateGateTests {
  private static let zoneID = CKRecordZone.ID(
    zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)
  private static let tOlder = Date(timeIntervalSince1970: 1_700_000_000)
  private static let tNewer = Date(timeIntervalSince1970: 1_700_000_060)

  /// Seeds a clean leg row at `quantity`, caching system fields stamped at
  /// `cachedDate`. Returns the row id.
  @MainActor
  private func seedCleanLeg(
    _ harness: ProfileDataSyncHandlerTestSupport.HandlerHarness,
    quantity: Int64,
    cachedDate: Date
  ) async throws -> UUID {
    let id = UUID()
    let repo = harness.handler.grdbRepositories.transactionLegs
    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { database in
      try ProfileDataSyncHandlerTestSupport.transactionLegRow(
        id: id, transactionId: UUID(), accountId: nil, quantity: quantity
      ).insert(database)
    }
    let row = try #require(try repo.fetchRowSync(id: id))
    _ = try repo.setEncodedSystemFieldsSync(
      id: id,
      data: row.toCKRecord(in: Self.zoneID).withModificationDate(cachedDate).encodedSystemFields)
    return id
  }

  private func legEcho(id: UUID, quantity: Int64, date: Date) -> CKRecord {
    ProfileDataSyncHandlerTestSupport.transactionLegRow(
      id: id, transactionId: UUID(), accountId: nil, quantity: quantity
    ).toCKRecord(in: Self.zoneID).withModificationDate(date)
  }

  private func quantity(
    _ harness: ProfileDataSyncHandlerTestSupport.HandlerHarness, id: UUID
  ) async throws -> Int64? {
    try await harness.database.read { try TransactionLegRow.fetchOne($0, key: id)?.quantity }
  }

  @Test("clean row rejects an echo older than its cached version")
  func cleanPathRejectsOlderEcho() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    }
    let id = try await seedCleanLeg(harness, quantity: 200, cachedDate: Self.tNewer)

    _ = harness.handler.applyRemoteChanges(
      saved: [legEcho(id: id, quantity: 1, date: Self.tOlder)], deleted: [])

    #expect(try await quantity(harness, id: id) == 200)
  }

  @Test("clean row rejects an echo with a tied modification date (reject-on-tie)")
  func cleanPathRejectsTie() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    }
    let id = try await seedCleanLeg(harness, quantity: 200, cachedDate: Self.tOlder)

    _ = harness.handler.applyRemoteChanges(
      saved: [legEcho(id: id, quantity: 1, date: Self.tOlder)], deleted: [])

    #expect(try await quantity(harness, id: id) == 200)
  }

  @Test("dirty row keeps its unsent local edit against a newer-dated peer change")
  func dirtyRowGuardSurvivesNewerPeerChange() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    }
    let id = UUID()
    let repo = harness.handler.grdbRepositories.transactionLegs
    // Unsent local edit: dirty row at qty 200, cached at the older acked date.
    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { database in
      try ProfileDataSyncHandlerTestSupport.transactionLegRow(
        id: id, transactionId: UUID(), accountId: nil, quantity: 200
      ).insert(database)
      try repo.markNeedsPushSync(id: id, in: database)
    }
    let row = try #require(try repo.fetchRowSync(id: id))
    _ = try repo.setEncodedSystemFieldsSync(
      id: id,
      data: row.toCKRecord(in: Self.zoneID).withModificationDate(Self.tOlder).encodedSystemFields)

    // A genuine, strictly-NEWER peer change must NOT overwrite the unsent
    // local edit — the dirty-path guard, not the date gate, protects it.
    _ = harness.handler.applyRemoteChanges(
      saved: [legEcho(id: id, quantity: 500, date: Self.tNewer)], deleted: [])

    #expect(try await quantity(harness, id: id) == 200)
  }

  @Test("cached date advances on apply, so a later stale echo is rejected")
  func cachedDateAdvancesOnApply() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    }
    let id = try await seedCleanLeg(harness, quantity: 100, cachedDate: Self.tOlder)

    // Genuine newer change applies and advances the cached date to tNewer.
    _ = harness.handler.applyRemoteChanges(
      saved: [legEcho(id: id, quantity: 500, date: Self.tNewer)], deleted: [])
    #expect(try await quantity(harness, id: id) == 500)

    // A stale echo at tOlder (< the now-cached tNewer) is rejected.
    _ = harness.handler.applyRemoteChanges(
      saved: [legEcho(id: id, quantity: 100, date: Self.tOlder)], deleted: [])
    #expect(try await quantity(harness, id: id) == 500)
  }

  @Test("within one batch the newest-dated version wins even when not last in the array")
  func withinBatchDedupToMaxKeepsNewest() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    }
    // First-sync clean row (nil cached date → fail-open), so the within-batch
    // dedup-to-max is the only thing deciding which version lands.
    let id = UUID()
    // Newest (tNewer, qty 500) appears BEFORE the older (tOlder, qty 1) in the array.
    let newest = legEcho(id: id, quantity: 500, date: Self.tNewer)
    let older = legEcho(id: id, quantity: 1, date: Self.tOlder)

    _ = harness.handler.applyRemoteChanges(saved: [newest, older], deleted: [])

    #expect(try await quantity(harness, id: id) == 500)
  }
}
