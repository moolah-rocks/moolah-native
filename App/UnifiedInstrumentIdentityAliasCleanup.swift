// App/UnifiedInstrumentIdentityAliasCleanup.swift

import Foundation
import GRDB
import OSLog

/// One-shot startup cleanup that physically deletes aliased retired crypto
/// `instrument` rows from the shared registry and tombstones each via a
/// `DeletionJournal` write in the same transaction, so other devices delete
/// rather than resurrect them.
///
/// NOT a `DatabaseMigrator` step: it needs to run after PR5's identity
/// migration has completed on THIS device and is gated accordingly.
/// The write is a single SQLite transaction so a mid-run kill leaves the
/// database byte-identical (no partial deletes).
@MainActor
struct UnifiedInstrumentIdentityAliasCleanup {
  let profileIndexDatabase: DatabaseQueue
  let userDefaults: UserDefaults

  /// Test-only fault seam: when non-nil, called inside the write transaction
  /// after the first successful delete, so a test can prove the whole write
  /// rolls back byte-identical on throw. Always `nil` in production.
  /// `@Sendable` because it runs inside GRDB's `write` closure.
  var faultAfterFirstDeleteForTesting: (@Sendable (Database) throws -> Void)?

  /// `UserDefaults` key in `.moolahShared` that marks this cleanup complete.
  /// `nonisolated`: a string constant with no mutable state; safe to read
  /// from any isolation domain.
  nonisolated static let gateKey = "didDeleteUnifiedInstrumentIdentityAliases"

  /// `true` when the cleanup has already run successfully on this device.
  static func isComplete(in defaults: UserDefaults = .moolahShared) -> Bool {
    defaults.bool(forKey: gateKey)
  }

  /// Removes the completion flag. `--ui-testing` only — each UI-test launch
  /// is a fresh in-memory container, so stale flags must not short-circuit
  /// the cleanup. No production code path should invoke this.
  static func resetGateFlag(in defaults: UserDefaults) {
    defaults.removeObject(forKey: gateKey)
  }

  private static let logger = Logger(
    subsystem: "com.moolah.app", category: "UnifiedInstrumentIdentityAliasCleanup")

  /// Runs the alias cleanup end-to-end if it has not already completed.
  ///
  /// Orchestration order (idempotent; flag last):
  /// 1. Own-flag short-circuit — if already done, return immediately.
  /// 2. PR5-flag guard — if PR5 has not yet completed on this device, return
  ///    WITHOUT setting the PR6 flag (deferred to next launch).
  /// 3. Cancellation guard.
  /// 4. ONE `write`: fetch all `alias_of IS NOT NULL` ids; for each id,
  ///    `deleteOne` + `DeletionJournal.record` (same transaction).
  /// 5. Cancellation guard; set PR6 flag LAST (even if zero rows deleted).
  func run() async throws {
    guard !Self.isComplete(in: userDefaults) else {
      Self.logger.info("Alias cleanup already complete — skipping")
      return
    }
    guard UnifiedInstrumentIdentityMigration.isComplete(in: userDefaults) else {
      Self.logger.info(
        "Alias cleanup deferred: PR5 migration not yet complete on this device")
      return
    }
    guard !Task.isCancelled else { return }

    // Capture the fault seam by value so the `@Sendable` write closure can
    // call it without crossing actor isolation — the closure body is
    // synchronous and runs on GRDB's writer thread, not on `@MainActor`.
    let fault = faultAfterFirstDeleteForTesting

    let deletedCount = try await profileIndexDatabase.write { database -> Int in
      let ids = try String.fetchAll(
        database, sql: "SELECT id FROM instrument WHERE alias_of IS NOT NULL")
      var count = 0
      var faultFired = false
      for id in ids {
        let didDelete = try InstrumentRow.deleteOne(database, key: id)
        if didDelete {
          try DeletionJournal.record(
            zoneName: DeletionJournal.profileIndexZoneName,
            recordName: InstrumentRow.recordName(for: id),
            recordType: InstrumentRow.recordType,
            at: Date(),
            in: database)
          count += 1
          if !faultFired {
            try fault?(database)
            faultFired = true
          }
        }
      }
      return count
    }

    guard !Task.isCancelled else { return }
    userDefaults.set(true, forKey: Self.gateKey)
    Self.logger.info(
      "Alias cleanup complete: \(deletedCount, privacy: .public) retired row(s) deleted")
  }
}
