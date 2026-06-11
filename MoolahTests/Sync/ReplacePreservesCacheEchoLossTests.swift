@preconcurrency import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Regression harness for the confirmed automation-write-path gap (issue
/// #1090 follow-up to the #1085 modification-date gate; task #14).
///
/// ## The gap
///
/// The automation leg edits (`AutomationService.updateLeg` / `addLeg` /
/// `removeLeg`) all funnel through `AutomationService.save(...)`, which calls
/// `transactions.replace(deletingIds: [txId], creating: [rebuilt])` — a
/// delete-then-insert that keeps the SAME `TransactionLeg.id` (the automation
/// layer rebuilds the leg "keeping id"). `GRDBTransactionRepository.replace`
/// deletes the old leg row and re-inserts a fresh one via `performCreateMany`,
/// which leaves `encoded_system_fields == nil` on the re-created same-id row
/// (a fresh insert has no cached server blob).
///
/// That nil cache is the hole the #1085 gate falls through: the
/// modification-date gate is deliberately fail-OPEN when the cached date is
/// nil (`applicableAfterDateGate` returns `true` for an absent cached date,
/// so a genuine first-time peer change is never dropped). So once the
/// re-created leg is clean again (`needs_push == 0`), a STALE self-echo of the
/// deleted placeholder version — still queued from an earlier upload batch —
/// is applied unconditionally and clobbers the real edit back to the
/// placeholder. This is the live STEP-3 symptom: a placeholder leg
/// (AUD/income/qty 1) updated to a real token leg reverts to the placeholder,
/// and `needs_push == 0` on the lost rows.
///
/// Unlike the in-place `performUpdate` path — which snapshots each surviving
/// leg's blob and re-attaches it (`GRDBTransactionRepository+Update.swift`),
/// so the cache is never nil and the gate protects unconditionally — the
/// `replace` path has no such re-attach. The traced flows survive only because
/// `replace` re-raises `needs_push = 1`, and a dirty row takes the
/// system-fields-only apply path (protected) rather than the clobbering
/// upsert. That is a timing invariant, not an unconditional guarantee: the
/// moment the row goes clean with a nil cache, the clobber is live.
///
/// ## The fix these tests pin (task #14)
///
/// `replace` / `performCreateMany` must snapshot the deleted rows'
/// `encoded_system_fields` by id and re-attach them to any re-created same-id
/// row — exactly as `performUpdate` already does. With the cache preserved,
/// the gate sees the placeholder echo's date as `<=` the cached date and
/// rejects it (reject-on-tie), so the real edit survives regardless of the
/// `needs_push` timing.
///
/// ## State of these tests
///
/// Both are RED against current `main` and go GREEN once `replace` preserves
/// the blob. The fix lives in `replace` / `performCreateMany`, NOT the gate,
/// so it is safe regardless of whether any single deterministic echo trace
/// reproduces the live loss.
@Suite("replace must preserve encoded_system_fields so a stale echo can't clobber a reused leg id")
struct ReplacePreservesCacheEchoLossTests {
  /// The post-`replace` fixture the two tests assert against.
  private struct Fixture {
    let harness: ProfileDataSyncHandlerTestSupport.HandlerHarness
    let legId: UUID
    /// Stale echo of the deleted placeholder version, stamped with the older
    /// server date.
    let placeholderEcho: CKRecord
    /// The token leg's stored (scaled minor-unit) quantity as persisted by
    /// `replace` — the survivor is asserted against this.
    let tokenStoredQuantity: Int64
  }

  /// Echoes are stamped in a fixed zone; `applyRemoteChanges` dispatches by
  /// record type + name, so the zone need not match the handler's own.
  private static let zoneID = CKRecordZone.ID(
    zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

  /// The placeholder version's server date is OLDER than any later edit, so a
  /// preserved cache rejects its stale echo on a tie-or-older comparison.
  private static let tPlaceholder = Date(timeIntervalSince1970: 1_700_000_000)

  private static let placeholderQuantity: Int64 = 1
  private static let tokenQuantity: Int64 = 200

  /// Builds the placeholder transaction (header + one leg) through the REAL
  /// `create` path, acks the placeholder leg's server system fields (so it has
  /// a non-nil cached blob, like a fully-synced row), then drives the REAL
  /// automation update shape — `replace(deletingIds: [txId], creating:
  /// [rebuilt])` keeping the same leg id — swapping the placeholder leg for the
  /// real token leg.
  ///
  /// Returns the post-`replace` `Fixture`: the handler harness, the reused leg
  /// id, the stale placeholder echo, and the token leg's stored quantity (the
  /// leg row stores a scaled minor-unit `Int64`, so the survivor is asserted
  /// against this captured value rather than a raw domain number).
  private func seedPlaceholderThenReplaceWithToken() async throws -> Fixture {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    }
    let transactionId = UUID()
    let legId = UUID()
    let accountId = UUID()
    let transactions = harness.handler.grdbRepositories.transactions
    let legs = harness.handler.grdbRepositories.transactionLegs

    // create (placeholder): AUD/income/qty 1 — header + leg, both dirty.
    let placeholder = Transaction(
      id: transactionId,
      date: Self.tPlaceholder,
      payee: "Buy",
      legs: [
        TransactionLeg(
          id: legId,
          accountId: accountId,
          instrument: .defaultTestInstrument,
          quantity: Decimal(Self.placeholderQuantity),
          type: .income)
      ])
    _ = try await transactions.create(placeholder)

    // ack: cache the placeholder leg's (non-nil) server system fields stamped
    // with the OLDER date — this is the version that echoes back stale — then
    // clear needs_push so the placeholder leg is clean + cached (fully synced).
    let placeholderRow = try #require(try legs.fetchRowSync(id: legId))
    let placeholderEcho =
      placeholderRow
      .toCKRecord(in: Self.zoneID)
      .withModificationDate(Self.tPlaceholder)
    _ = try legs.setEncodedSystemFieldsSync(
      id: legId, data: placeholderEcho.encodedSystemFields)
    _ = try legs.clearNeedsPushBatchSync([legId])

    // automation update → replace: rebuild keeping the SAME leg id, swap the
    // placeholder for the real token (qty 200). This is the exact call
    // `AutomationService.save(...)` issues.
    let tokenTransaction = Transaction(
      id: transactionId,
      date: Self.tPlaceholder,
      payee: "Buy",
      legs: [
        TransactionLeg(
          id: legId,
          accountId: accountId,
          instrument: .defaultTestInstrument,
          quantity: Decimal(Self.tokenQuantity),
          type: .income)
      ])
    _ = try await transactions.replace(
      deletingIds: [transactionId], creating: [tokenTransaction])

    // Capture the token leg's stored (scaled) quantity straight after the
    // replace, before any echo, so the survivor assertions compare against the
    // real persisted value.
    let tokenRow = try #require(try legs.fetchRowSync(id: legId))
    return Fixture(
      harness: harness,
      legId: legId,
      placeholderEcho: placeholderEcho,
      tokenStoredQuantity: tokenRow.quantity)
  }

  /// Structural pin: after a same-id `replace`, the re-created leg row MUST
  /// keep the deleted row's cached `encoded_system_fields`. RED today
  /// (`replace` → `performCreateMany` inserts a fresh row with a nil blob);
  /// GREEN once the fix snapshots + re-attaches the blob by id.
  @Test("replace preserves the cached system fields on the re-created same-id leg")
  func replacePreservesCachedSystemFieldsForReusedLegId() async throws {
    let fixture = try await seedPlaceholderThenReplaceWithToken()

    let row = try await fixture.harness.database.read { database in
      try TransactionLegRow.fetchOne(database, key: fixture.legId)
    }
    // The load-bearing assertion: a non-nil cache is what lets the #1085 gate
    // protect the row unconditionally.
    #expect(try #require(row).encodedSystemFields != nil)
  }

  /// End-to-end loss pin: the real edit must survive a stale echo of the
  /// deleted placeholder version arriving on a now-clean row.
  ///
  /// `needs_push` is cleared after `replace` to model the observed production
  /// state — the live STEP-3 placeholder legs were `needs_push == 0` when they
  /// reverted. A clean row with a nil cache is the only state in which the
  /// clean-path date gate runs, and it is precisely where the gap bites: the
  /// dirty-path guard (`needs_push == 1`) that protects the traced flows no
  /// longer applies.
  ///
  /// RED today: nil cache → gate fails open → the stale placeholder echo (qty
  /// 1) clobbers the token (qty 200). GREEN once `replace` preserves the blob:
  /// the placeholder echo's date is `<=` the cached date → rejected.
  @Test("token leg survives a stale placeholder echo after an automation replace")
  func tokenLegSurvivesStalePlaceholderEchoAfterReplace() async throws {
    let fixture = try await seedPlaceholderThenReplaceWithToken()
    let legs = fixture.harness.handler.grdbRepositories.transactionLegs

    // Model the observed production state: the re-created token leg has gone
    // clean (its own upload acked / confirmed) while its cache reflects only
    // the cache-nulling replace.
    _ = try legs.clearNeedsPushBatchSync([fixture.legId])

    // The stale placeholder echo — still queued from the pre-edit upload —
    // arrives last, on a clean row.
    let stale = fixture.harness.handler.applyRemoteChanges(
      saved: [fixture.placeholderEcho], deleted: [])
    if case .saveFailed(let message) = stale {
      Issue.record("stale save failed: \(message)")
    }

    let row = try await fixture.harness.database.read { database in
      try TransactionLegRow.fetchOne(database, key: fixture.legId)
    }
    // The real edit must survive the out-of-order stale echo.
    #expect(try #require(row).quantity == fixture.tokenStoredQuantity)
  }
}
