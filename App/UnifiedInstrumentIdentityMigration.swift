// App/UnifiedInstrumentIdentityMigration.swift

import Foundation
import GRDB
import OSLog

/// One-shot app-side migration collapsing retired per-chain crypto identities
/// onto their canonical id across the shared registry AND every profile's data.
///
/// NOT a `DatabaseMigrator` step: it needs `profile-index.sqlite` and each
/// profile's `data.sqlite` at once plus the `CanonicalInstrumentResolver`.
@MainActor
struct UnifiedInstrumentIdentityMigration {
  let profileIndexDatabase: DatabaseQueue
  /// `@MainActor` (not `@Sendable`): the only call site is `rewriteProfile`, itself
  /// `@MainActor`, and the production provider hops to `ProfileContainerManager`
  /// (a `@MainActor` type). Typing it `@MainActor` makes that requirement a
  /// compile-time guarantee instead of a `MainActor.assumeIsolated` runtime trap.
  let dataDatabaseProvider: @MainActor (UUID) throws -> DatabaseQueue
  let allProfileIds: @Sendable () async -> [UUID]
  let registry: any AliasedCryptoRegistrationProvider
  let resolver: CanonicalInstrumentResolver
  let rePush: @MainActor (UUID) async -> Void
  let userDefaults: UserDefaults

  /// Test-only fault seam: when non-nil, `rewriteProfile` calls this closure
  /// after its first statement, inside the active `write` transaction, so a
  /// test can prove SQLite rolls the whole `IMMEDIATE` transaction back. Always
  /// nil in production. `@Sendable` because it runs inside GRDB's `write`
  /// closure.
  var faultAfterFirstStatementForTesting: (@Sendable (Database) throws -> Void)?

  /// Test-only seam: when non-nil, `rewriteProfile` throws `ProfileRewriteTestFault`
  /// for the matching profile UUID inside the `write` transaction (so GRDB rolls
  /// that profile back byte-identical). Proves cross-profile resumability: a fault
  /// on profile B leaves A fully rewritten and B untouched. Always nil in production.
  var faultOnProfile: UUID?

  /// `UserDefaults` key in `.moolahShared` that marks the migration complete.
  /// `nonisolated`: a string constant with no mutable state; safe to read
  /// from any isolation domain.
  nonisolated static let gateKey = "didMigrateUnifiedInstrumentIdentity"

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

  /// Runs the migration end-to-end if it has not already completed.
  ///
  /// Orchestration order (every step idempotent; flag last):
  /// 1. Gate: completion flag set → return immediately.
  /// 2. Derive retired→canonical mapping from the unfiltered registry.
  /// 3. Alias step (shared DB): set `alias_of` on every retired row.
  /// 4. Per-profile loop: rewrite FKs (atomic per profile) then re-push.
  /// 5. Price-cache step (shared DB): fold meta dates + purge retired caches.
  /// 6. Set the completion flag — only after ALL steps succeed for ALL profiles.
  ///
  /// A kill between any two steps leaves the flag `false`; the next launch
  /// re-derives the same mapping (retired rows still present + aliased) and
  /// re-applies each step idempotently. Finished profiles are no-ops; unfinished
  /// profiles get rewritten. The flag is only set after full convergence.
  func run() async throws {
    guard !Self.isComplete(in: userDefaults) else {
      Self.logger.info("Unified identity migration already complete — skipping")
      return
    }
    guard !Task.isCancelled else { return }

    let mapping = try await deriveMapping()
    try await applyAliasStep(mapping: mapping)

    for profileId in await allProfileIds() {
      guard !Task.isCancelled else { return }
      try await rewriteProfile(profileId, mapping: mapping)
      await rePush(profileId)
    }

    try await applyPriceCacheStep(mapping: mapping)
    guard !Task.isCancelled else { return }
    userDefaults.set(true, forKey: Self.gateKey)
    Self.logger.info(
      "Unified identity migration complete: \(mapping.count, privacy: .public) retired id(s) rewritten"
    )
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

extension UnifiedInstrumentIdentityMigration {
  /// Thrown by `rewriteProfile` when `faultOnProfile` matches the profile being
  /// rewritten. Thrown inside the `write` transaction so GRDB rolls the profile
  /// back byte-identical. Test-only; never emitted in production.
  struct ProfileRewriteTestFault: Error {}
}
