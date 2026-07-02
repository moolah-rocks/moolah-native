// Domain/Repositories/AliasedCryptoRegistrationProvider.swift
import Foundation

/// Narrow seam used exclusively by `UnifiedInstrumentIdentityMigration` to
/// read the UNFILTERED crypto registration set (including retired/aliased
/// rows). Kept separate from `InstrumentRegistryRepository` because the
/// only caller is the one-shot migration; production read paths must use
/// `allCryptoRegistrations()` on that protocol, which excludes aliased rows
/// via the `alias_of IS NULL` filter.
///
/// No production code path should use this protocol outside the migration.
protocol AliasedCryptoRegistrationProvider: Sendable {
  /// All registered crypto instruments INCLUDING aliased (retired) rows.
  /// Identical projection rules to `allCryptoRegistrations()` except the
  /// `alias_of IS NULL` filter is absent, so retired cross-chain ids
  /// (e.g. `10:native` aliased to `1:native`) are included.
  ///
  /// Throws on a backing-store failure.
  func allCryptoRegistrationsIncludingAliased() async throws -> [CryptoRegistration]
}
