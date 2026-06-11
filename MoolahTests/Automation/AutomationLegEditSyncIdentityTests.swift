@preconcurrency import CloudKit
import Foundation
import Testing

@testable import Moolah

/// Pins Fix #1 of the automation-write-path gap (issue #1090 follow-up): the
/// genuine `AutomationService.updateLeg` verb must preserve the edited leg's
/// cached `encoded_system_fields` (its CloudKit sync identity).
///
/// `updateLeg` / `addLeg` / `removeLeg` funnel through `save(...)`, which now
/// calls `transactions.update(_:)` (an in-place, diff-by-id upsert that
/// re-attaches each surviving leg's blob) instead of
/// `replace(deletingIds:creating:)` (a delete-then-insert that nulled the
/// blob on the re-created same-id row). With a nil cache, a clean row falls
/// through the #1085 modification-date gate's fail-open and a stale self-echo
/// reverts the edit — the placeholder-revert data loss.
///
/// RED before Fix #1 (`save` → `replace` nulls the cache); GREEN after
/// (`save` → `update` preserves it).
@MainActor
@Suite("automation leg edits preserve the leg's CloudKit sync identity")
struct AutomationLegEditSyncIdentityTests {
  private static let zoneID = CKRecordZone.ID(
    zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

  @Test("updateLeg keeps the leg's cached system fields and applies the edit")
  func updateLegPreservesLegSyncIdentity() async throws {
    let (service, session) = try await AutomationTestSession.make()
    let backend = try #require(session.backend as? CloudKitBackend)
    let legs = backend.grdbTransactionLegs

    let bank = try await service.createAccount(
      profileIdentifier: "Test", name: "Bank", type: .bank)
    let transaction = try await LegTestSupport.makeSingleLeg(
      session: session, accountId: bank.id, quantity: 1, payee: "Buy")
    let legId = try #require(transaction.legs.first).id

    // Ack the leg: stamp a non-nil cached server system-fields blob, modelling
    // a fully round-tripped (clean, synced) leg.
    let row = try #require(try legs.fetchRowSync(id: legId))
    _ = try legs.setEncodedSystemFieldsSync(
      id: legId, data: row.toCKRecord(in: Self.zoneID).encodedSystemFields)

    // Edit the leg through the real automation verb.
    let updated = try await service.updateLeg(
      profileIdentifier: "Test",
      legId: legId,
      changes: AutomationService.LegChanges(amount: 200))

    // The edit applied …
    #expect(updated.legs.first { $0.id == legId }?.quantity == 200)
    // … and the leg kept its CloudKit sync identity (Fix #1: update, not
    // replace). A nil cache here is the gap that lets a stale echo clobber.
    let editedRow = try #require(try legs.fetchRowSync(id: legId))
    #expect(editedRow.encodedSystemFields != nil)
  }
}
