// App/UnifiedInstrumentIdentityMigration.swift

import Foundation
import GRDB
import OSLog

/// One-shot app-side migration collapsing retired per-chain crypto identities
/// onto their canonical id across the shared registry AND every profile's data.
/// See `plans/2026-07-01-unified-instrument-identity-pr5-data-migration.md`.
///
/// NOT a `DatabaseMigrator` step: it needs `profile-index.sqlite` and each
/// profile's `data.sqlite` at once plus the `CanonicalInstrumentResolver`.
@MainActor
struct UnifiedInstrumentIdentityMigration {
  let profileIndexDatabase: DatabaseQueue
  let dataDatabaseProvider: @Sendable (UUID) throws -> DatabaseQueue
  let allProfileIds: @Sendable () async -> [UUID]
  let registry: any InstrumentRegistryRepository
  let resolver: CanonicalInstrumentResolver
  let rePush: @MainActor (UUID) async -> Void
  let userDefaults: UserDefaults

  /// Test-only fault seam: when non-nil, `rewriteProfile` calls this closure
  /// after its first statement, inside the active `write` transaction, so a
  /// test can prove SQLite rolls the whole `IMMEDIATE` transaction back. Always
  /// nil in production. `@Sendable` because it runs inside GRDB's `write`
  /// closure.
  var faultAfterFirstStatementForTesting: (@Sendable (Database) throws -> Void)?

  /// `UserDefaults` key in `.moolahShared` that marks the migration complete.
  static let gateKey = "didMigrateUnifiedInstrumentIdentity"

  /// `true` when the migration has already run successfully on this device.
  static func isComplete(in defaults: UserDefaults = .moolahShared) -> Bool {
    defaults.bool(forKey: gateKey)
  }

  /// Removes the completion flag. `--ui-testing` only — each UI-test launch
  /// is a fresh in-memory container, so stale flags must not short-circuit
  /// the migration. No production code path should invoke this.
  static func resetGateFlag(in defaults: UserDefaults) {
    defaults.removeObject(forKey: gateKey)
  }

  private static let logger = Logger(
    subsystem: "com.moolah.app", category: "UnifiedInstrumentIdentityMigration")

  /// Runs the migration if it has not already completed, returning immediately
  /// when the gate flag is set. The orchestration body (alias writes, FK
  /// rewrites, price-cache purge, re-push) is not yet wired up; the function
  /// currently performs only the gate-flag check.
  func run() async throws {
    guard !Self.isComplete(in: userDefaults) else {
      Self.logger.info("Already complete — skipping")
      return
    }
    // Orchestration body not yet implemented.
  }

  /// Derives the retired id → canonical id mapping from the UNFILTERED shared
  /// registry. Populates the resolver's dynamic layer with all registrations
  /// (including retired ones) so ERC-20s absent from the static base map are
  /// also resolved.
  ///
  /// Only ids that resolve to a *different* canonical id appear as keys —
  /// canonicals and no-key tokens map to themselves and are excluded.
  func deriveMapping() async throws -> [String: String] {
    let registrations = try await registry.allCryptoRegistrationsIncludingAliased()
    resolver.refresh(with: registrations)
    var mapping: [String: String] = [:]
    for registration in registrations {
      let id = registration.instrument.id
      let canonical = resolver.canonicalId(for: id)
      if canonical != id { mapping[id] = canonical }
    }
    return mapping
  }
}
