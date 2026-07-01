import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Verifies the CloudKit apply path rewrites an un-migrated peer's retired
/// cross-chain instrument id onto its canonical id before storing FK-holding
/// records (design §3.4).
@Suite("ProfileDataSyncHandler — instrument-id canonicalization on apply")
struct ProfileHandlerCanonicalizationTests {

  @Test
  func incomingOptimismNativeLegStoredAsCanonicalMainnet() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerAndDatabase(
        canonicalResolver: CanonicalInstrumentResolver())
    }
    let handler = harness.handler

    // Seed the parent transaction so the leg has a valid FK target.
    let txId = UUID()
    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { database in
      try ProfileDataSyncHandlerTestSupport
        .transactionRow(id: txId, payee: "ETH transfer").insert(database)
    }

    let legId = UUID()
    let leg = ProfileDataSyncHandlerTestSupport.transactionLegRow(
      id: legId,
      transactionId: txId,
      accountId: UUID(),
      instrumentId: "10:native")  // Optimism ETH, from an un-migrated peer.
    let ckRecord = leg.toCKRecord(in: handler.zoneID)

    _ = handler.applyRemoteChanges(saved: [ckRecord], deleted: [])

    let stored = try await harness.database.read { database in
      try TransactionLegRow
        .filter(TransactionLegRow.Columns.id == legId)
        .fetchOne(database)
    }
    #expect(stored?.instrumentId == "1:native")
  }

  @Test
  func incomingLegWithNilResolverStoredUnchanged() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerAndDatabase(
        canonicalResolver: nil)
    }
    let handler = harness.handler

    let txId = UUID()
    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { database in
      try ProfileDataSyncHandlerTestSupport
        .transactionRow(id: txId, payee: "ETH transfer").insert(database)
    }

    let legId = UUID()
    let leg = ProfileDataSyncHandlerTestSupport.transactionLegRow(
      id: legId,
      transactionId: txId,
      accountId: UUID(),
      instrumentId: "10:native")
    let ckRecord = leg.toCKRecord(in: handler.zoneID)

    _ = handler.applyRemoteChanges(saved: [ckRecord], deleted: [])

    let stored = try await harness.database.read { database in
      try TransactionLegRow
        .filter(TransactionLegRow.Columns.id == legId)
        .fetchOne(database)
    }
    #expect(stored?.instrumentId == "10:native")
  }

  @Test
  func incomingEarmarkCanonicalizesBothInstrumentColumns() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerAndDatabase(
        canonicalResolver: CanonicalInstrumentResolver())
    }
    let handler = harness.handler

    let earmarkId = UUID()
    var earmark = ProfileDataSyncHandlerTestSupport.earmarkRow(
      id: earmarkId, name: "ETH goal", instrumentId: "10:native")
    earmark.savingsTargetInstrumentId = "8453:native"  // Base ETH.
    let ckRecord = earmark.toCKRecord(in: handler.zoneID)

    _ = handler.applyRemoteChanges(saved: [ckRecord], deleted: [])

    let stored = try await harness.database.read { database in
      try EarmarkRow.filter(EarmarkRow.Columns.id == earmarkId).fetchOne(database)
    }
    #expect(stored?.instrumentId == "1:native")
    #expect(stored?.savingsTargetInstrumentId == "1:native")
  }

  @Test
  func incomingEarmarkWithNilResolverStoredUnchanged() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerAndDatabase(canonicalResolver: nil)
    }
    let handler = harness.handler

    let earmarkId = UUID()
    var earmark = ProfileDataSyncHandlerTestSupport.earmarkRow(
      id: earmarkId, name: "ETH goal", instrumentId: "10:native")
    earmark.savingsTargetInstrumentId = "8453:native"
    let ckRecord = earmark.toCKRecord(in: handler.zoneID)

    _ = handler.applyRemoteChanges(saved: [ckRecord], deleted: [])

    let stored = try await harness.database.read { database in
      try EarmarkRow.filter(EarmarkRow.Columns.id == earmarkId).fetchOne(database)
    }
    #expect(stored?.instrumentId == "10:native")
    #expect(stored?.savingsTargetInstrumentId == "8453:native")
  }

  @Test
  func incomingEarmarkNilSavingsTargetInstrumentIdStaysNil() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerAndDatabase(
        canonicalResolver: CanonicalInstrumentResolver())
    }
    let handler = harness.handler

    let earmarkId = UUID()
    // earmarkRow sets savingsTargetInstrumentId = nil by default.
    let earmark = ProfileDataSyncHandlerTestSupport.earmarkRow(
      id: earmarkId, name: "ETH goal", instrumentId: "10:native")
    let ckRecord = earmark.toCKRecord(in: handler.zoneID)

    _ = handler.applyRemoteChanges(saved: [ckRecord], deleted: [])

    let stored = try await harness.database.read { database in
      try EarmarkRow.filter(EarmarkRow.Columns.id == earmarkId).fetchOne(database)
    }
    #expect(stored?.instrumentId == "1:native")
    #expect(stored?.savingsTargetInstrumentId == nil)
  }
}
