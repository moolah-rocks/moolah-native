// MoolahTests/App/UnifiedIdentityMigrationEndToEndTests.swift

import Foundation
import Testing

@testable import Moolah

// MARK: - End-to-end helpers

/// Asserts that all FK tables in `profileId`'s database carry only canonical
/// instrument ids (no retired `10:*` or `8453:*` prefixes). Extracted to keep
/// `endToEnd()` under `function_body_length`.
@MainActor
private func assertAllFKsCanonical(_ profileId: UUID, harness: MigrationTestHarness) async throws {
  let legIds = try await harness.allInstrumentIds(profileId, "transaction_leg")
  #expect(legIds.allSatisfy { !$0.hasPrefix("10:") && !$0.hasPrefix("8453:") })
  let earmarkIds = try await harness.allInstrumentIds(profileId, "earmark")
  #expect(earmarkIds.allSatisfy { !$0.hasPrefix("10:") && !$0.hasPrefix("8453:") })
  let ebiIds = try await harness.allInstrumentIds(profileId, "earmark_budget_item")
  #expect(ebiIds.allSatisfy { !$0.hasPrefix("10:") && !$0.hasPrefix("8453:") })
  let groupIds = try await harness.allInstrumentIds(profileId, "account_group")
  #expect(groupIds.allSatisfy { !$0.hasPrefix("10:") && !$0.hasPrefix("8453:") })
  let ivIds = try await harness.allInstrumentIds(profileId, "investment_value")
  #expect(ivIds.allSatisfy { !$0.hasPrefix("10:") && !$0.hasPrefix("8453:") })
  let acctIds = try await harness.allInstrumentIds(profileId, "account")
  #expect(acctIds.allSatisfy { !$0.hasPrefix("10:") && !$0.hasPrefix("8453:") })
}

// MARK: - Kill-mid-run helpers

/// Runs the faulted first pass: seeds two profiles, faults on B, asserts A is
/// rewritten + re-pushed while B is byte-identical and the flag is unset.
/// Extracted to keep `killMidRunIsResumable()` under `function_body_length`.
@MainActor
private func runFaultedPass(
  harness: MigrationTestHarness,
  profileA: UUID,
  profileB: UUID,
  snapshotBBefore: [String: [String]]
) async throws {
  var crashing = harness.migration(profileIds: [profileA, profileB])
  crashing.faultOnProfile = profileB

  await #expect(throws: (any Error).self) {
    try await crashing.run()
  }

  // A was fully rewritten and re-pushed.
  let legIdsA = try await harness.allInstrumentIds(profileA, "transaction_leg")
  #expect(legIdsA.allSatisfy { $0 == "1:native" })
  #expect(await harness.rePushRecorder.ids == [profileA])

  // B was rolled back byte-identical (per-profile atomicity).
  let snapshotBAfter = try await harness.snapshotAllTables(profileB)
  #expect(snapshotBAfter == snapshotBBefore)

  // Completion flag must NOT be set — the run did not finish.
  #expect(!UnifiedInstrumentIdentityMigration.isComplete(in: harness.userDefaults))
}

/// Runs the clean second pass and asserts B is rewritten and the flag is set.
@MainActor
private func runCleanPass(
  harness: MigrationTestHarness,
  profileA: UUID,
  profileB: UUID
) async throws {
  try await harness.migration(profileIds: [profileA, profileB]).run()

  // B is now rewritten (A was a no-op — its legs are already canonical).
  let legIdsB = try await harness.allInstrumentIds(profileB, "transaction_leg")
  #expect(legIdsB.allSatisfy { $0 == "1:native" })

  // Completion flag set after full convergence.
  #expect(UnifiedInstrumentIdentityMigration.isComplete(in: harness.userDefaults))
}

// MARK: - Tests

@MainActor
@Suite("UnifiedIdentityMigration: end-to-end")
struct UnifiedIdentityMigrationEndToEndTests {
  /// Full pipeline: alias step, per-profile FK rewrite + re-push, price-cache step,
  /// and completion flag, exercised over a profile seeded with retired ids, a
  /// canonical Coinstash leg, and an OP→Coinstash transfer pair. The second run
  /// short-circuits on the gate flag and leaves all state identical (idempotent).
  @Test("end-to-end: every FK canonical, retired rows aliased, transfer reconciles, idempotent")
  func endToEnd() async throws {
    let harness = try MigrationTestHarness.make()
    let profileId = UUID()
    try await harness.seedSharedRegistry([
      .ethMainnet, .ethOptimism, .ethBase, .usdcMainnet, .usdcOptimism,
    ])
    try await harness.seedFullProfile(profileId)

    try await harness.migration(profileIds: [profileId]).run()

    // All FK columns carry canonical ids (no 10:* / 8453:* suffixes).
    try await assertAllFKsCanonical(profileId, harness: harness)

    // Retired rows are aliased (not deleted) in the shared registry.
    #expect(try await harness.aliasOf("10:native") == "1:native")
    #expect(try await harness.aliasOf("8453:native") == "1:native")
    #expect(try await harness.rowExists("instrument", id: "10:native"))

    // OP→Coinstash transfer pair now shares a single instrument id.
    #expect(try await harness.transferLegsShareInstrument(profileId) == "1:native")

    // Completion flag is set.
    #expect(UnifiedInstrumentIdentityMigration.isComplete(in: harness.userDefaults))

    // Idempotent: a second run short-circuits on the flag; state is unchanged.
    let before = try await harness.snapshotAllTables(profileId)
    try await harness.migration(profileIds: [profileId]).run()
    let after = try await harness.snapshotAllTables(profileId)
    #expect(after == before)
  }

  /// RELEASE-BLOCKING: proves cross-profile kill-mid-run resumability.
  ///
  /// Two profiles: A (processed first) and B (faulted). A fault inside B's
  /// `write` transaction (via `faultOnProfile`) triggers a per-profile rollback,
  /// leaving B byte-identical while A is fully rewritten and re-pushed. The
  /// completion flag stays `false`. A clean re-run converges: A no-ops (legs
  /// already canonical), B is rewritten, flag is set. The result is correct
  /// regardless of where the kill occurs in the per-profile loop.
  @Test("a crash mid-run leaves a consistent prefix; the next launch converges (resumable)")
  func killMidRunIsResumable() async throws {
    let harness = try MigrationTestHarness.make()
    let profileA = UUID()
    let profileB = UUID()
    try await harness.seedSharedRegistry([.ethMainnet, .ethOptimism])
    try await harness.seedProfileWithRetiredLegs(profileA)
    try await harness.seedProfileWithRetiredLegs(profileB)
    let snapshotBBefore = try await harness.snapshotAllTables(profileB)

    try await runFaultedPass(
      harness: harness, profileA: profileA, profileB: profileB,
      snapshotBBefore: snapshotBBefore)

    try await runCleanPass(harness: harness, profileA: profileA, profileB: profileB)
  }
}
