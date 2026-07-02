// App/UnifiedInstrumentIdentityAliasCleanup.swift

import Foundation
import GRDB
import OSLog

/// One-shot startup cleanup that physically deletes aliased retired crypto
/// `instrument` rows from the shared registry and tombstones each via a
/// `DeletionJournal` write in the same transaction, so other devices delete
/// rather than resurrect them.
///
/// NOT a `DatabaseMigrator` step: it needs to run after the identity
/// migration (UnifiedInstrumentIdentityMigration) has completed on THIS
/// device and is gated accordingly.
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
  /// 2. Identity-migration guard — if UnifiedInstrumentIdentityMigration has
  ///    not yet completed on this device, return WITHOUT setting the own
  ///    completion flag (deferred to next launch).
  /// 3. Cancellation guard.
  /// 4. ONE `write`: fetch all `alias_of IS NOT NULL` ids; for each id,
  ///    raw `DELETE FROM instrument WHERE id = ?` + `DeletionJournal.record`
  ///    (same transaction). `recordName` is the bare `id`; `recordType` is
  ///    `"InstrumentRecord"` — frozen wire contract (InstrumentRow+Mapping.swift).
  /// 5. Cancellation guard; set the own completion flag LAST (even if zero
  ///    rows deleted).
  ///
  /// - Returns: The number of retired rows deleted (0 on early exit or no
  ///   aliased rows).
  @discardableResult
  func run() async throws -> Int {
    guard !Self.isComplete(in: userDefaults) else {
      Self.logger.info("Alias cleanup already complete — skipping")
      return 0
    }
    guard UnifiedInstrumentIdentityMigration.isComplete(in: userDefaults) else {
      Self.logger.info(
        "Alias cleanup deferred: identity migration (UnifiedInstrumentIdentityMigration) not yet complete on this device"
      )
      return 0
    }
    guard !Task.isCancelled else { return 0 }

    // Capture the fault seam by value so the `@Sendable` write closure can
    // call it without crossing actor isolation — the closure body is
    // synchronous and runs on GRDB's writer thread, not on `@MainActor`.
    let fault = faultAfterFirstDeleteForTesting

    let deletedCount = try await profileIndexDatabase.write { database -> Int in
      // Defense-in-depth: exclude fiat rows even though no fiat row is ever
      // aliased in practice — mirrors the same guard in
      // GRDBInstrumentRegistryRepository.remove(id:).
      let ids = try String.fetchAll(
        database,
        sql: "SELECT id FROM instrument WHERE alias_of IS NOT NULL AND kind != 'fiatCurrency'")
      var count = 0
      var faultFired = false
      for id in ids {
        try database.execute(sql: "DELETE FROM instrument WHERE id = ?", arguments: [id])
        guard database.changesCount > 0 else { continue }
        // recordName is the bare id and recordType is "InstrumentRecord" —
        // see InstrumentRow.recordName(for:) / InstrumentRow.recordType
        // (frozen wire contract in InstrumentRow+Mapping.swift).
        try DeletionJournal.record(
          zoneName: DeletionJournal.profileIndexZoneName,
          recordName: id,
          recordType: "InstrumentRecord",
          at: Date(),
          in: database)
        count += 1
        if !faultFired {
          try fault?(database)
          faultFired = true
        }
      }
      return count
    }

    guard !Task.isCancelled else { return 0 }
    userDefaults.set(true, forKey: Self.gateKey)
    Self.logger.info(
      "Alias cleanup complete: \(deletedCount, privacy: .public) retired row(s) deleted")
    return deletedCount
  }
}
