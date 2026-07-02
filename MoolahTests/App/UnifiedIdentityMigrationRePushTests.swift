// MoolahTests/App/UnifiedIdentityMigrationRePushTests.swift

import Foundation
import Testing

@testable import Moolah

@MainActor
@Suite("UnifiedIdentityMigration: re-push")
struct UnifiedIdentityMigrationRePushTests {
  /// Verifies that `run()` calls `queueAllRecordsAfterImport` exactly once for
  /// each rewritten profile, in the order the profiles are enumerated.
  @Test("run() re-pushes each profile via the injected rePush closure")
  func rePushesEachProfile() async throws {
    let harness = try MigrationTestHarness.make()
    let profileA = UUID()
    let profileB = UUID()
    try await harness.seedSharedRegistry([.ethMainnet, .ethOptimism])
    try await harness.seedProfileWithRetiredLegs(profileA)
    try await harness.seedProfileWithRetiredLegs(profileB)
    let recorder = harness.rePushRecorder

    try await harness.migration(profileIds: [profileA, profileB]).run()

    #expect(await recorder.ids == [profileA, profileB])
  }

  /// A single-profile sanity check: the closure is called with the correct UUID.
  @Test("run() re-pushes the single rewritten profile with the correct id")
  func rePushesSingleProfile() async throws {
    let harness = try MigrationTestHarness.make()
    let profileA = UUID()
    try await harness.seedSharedRegistry([.ethMainnet, .ethOptimism])
    try await harness.seedProfileWithRetiredLegs(profileA)
    let recorder = harness.rePushRecorder

    try await harness.migration(profileIds: [profileA]).run()

    #expect(await recorder.ids == [profileA])
  }

  /// A profile whose FK rows carry no retired ids (e.g. a fiat-only profile)
  /// must NOT trigger a re-push — the migration writes zero rows for it so
  /// `rePush` would cause a needless full CloudKit re-sync.
  ///
  /// Contrasted against a profile that DOES have retired-id rows to confirm
  /// that the gate is `changesCount > 0`, not "mapping is non-empty".
  @Test("run() skips rePush for a profile with no rows matching the mapping")
  func doesNotRePushWhenNoRowsChanged() async throws {
    let harness = try MigrationTestHarness.make()
    let profileWithRetired = UUID()
    let profileFiatOnly = UUID()
    try await harness.seedSharedRegistry([.ethMainnet, .ethOptimism])
    // Profile A: has retired-id rows → should be re-pushed.
    try await harness.seedProfileWithRetiredLegs(profileWithRetired)
    // Profile B: fiat-only (AUD) — no rows with retired ids → must NOT be re-pushed.
    let fiatQueue = try harness.cache.database(for: profileFiatOnly)
    let fiatLegId = UUID()
    try await fiatQueue.write { database in
      try database.execute(
        sql: "INSERT INTO transaction_leg "
          + "(id, record_name, transaction_id, instrument_id, quantity, type, sort_order) "
          + "VALUES (?, ?, ?, 'AUD', 50, 'expense', 0)",
        arguments: [fiatLegId, "TxLeg|\(fiatLegId.uuidString)", UUID()])
    }
    let recorder = harness.rePushRecorder

    try await harness.migration(profileIds: [profileWithRetired, profileFiatOnly]).run()

    // Only the profile with retired rows was re-pushed; the fiat-only profile was skipped.
    #expect(await recorder.ids == [profileWithRetired])
  }

  /// When the completion flag is already set, `run()` returns immediately without
  /// touching any profile. The `rePush` closure must NOT be invoked on the
  /// flag-short-circuit path.
  @Test("run() does not re-push when the completion flag is already set")
  func doesNotRePushWhenAlreadyComplete() async throws {
    let harness = try MigrationTestHarness.make()
    let profileA = UUID()
    try await harness.seedSharedRegistry([.ethMainnet, .ethOptimism])
    try await harness.seedProfileWithRetiredLegs(profileA)
    let recorder = harness.rePushRecorder

    // First run: migrates and re-pushes.
    try await harness.migration(profileIds: [profileA]).run()
    #expect(await recorder.ids.count == 1)

    // Second run: gate flag is set; rePush must NOT be called again.
    try await harness.migration(profileIds: [profileA]).run()

    // The recorder still shows exactly one invocation from the first run.
    #expect(await recorder.ids.count == 1)
  }
}
