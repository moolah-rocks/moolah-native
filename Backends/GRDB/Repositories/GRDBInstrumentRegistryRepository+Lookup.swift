// Backends/GRDB/Repositories/GRDBInstrumentRegistryRepository+Lookup.swift

import Foundation
import GRDB

extension GRDBInstrumentRegistryRepository {
  /// Looks up a single crypto registration by id. Mirrors the row-shape
  /// projection in `allCryptoRegistrations()` — see `project(row:)`
  /// below for the rule set.
  func cryptoRegistration(byId id: String) async throws -> CryptoRegistration? {
    try await database.read { database in
      let cryptoKind = Instrument.Kind.cryptoToken.rawValue
      guard
        let row =
          try InstrumentRow
          .filter(InstrumentRow.Columns.id == id)
          .filter(InstrumentRow.Columns.kind == cryptoKind)
          .fetchOne(database)
      else { return nil }
      return try Self.project(row: row)
    }
  }

  /// Returns IDs of non-fiat rows (stocks, crypto tokens) whose
  /// `encoded_system_fields` is `NULL`. Used by the per-startup
  /// targeted reconciliation in `SyncCoordinator+Backfill` (which runs
  /// unconditionally — *not* gated by the per-profile backfill flag) so
  /// rows inserted by a build that predated the shared-registry
  /// `registerResolvable` path eventually reach CloudKit. Fiat is
  /// filtered out because synthetic fiat rows shouldn't normally be
  /// persisted — they're synthesised at read time via
  /// `Locale.Currency.isoCurrencies` — and a stale one slipping into
  /// the table must not be uploaded as if user-registered.
  func unsyncedNonFiatRowIdsSync() throws -> [String] {
    let fiatKind = Instrument.Kind.fiatCurrency.rawValue
    return try database.read { database in
      try InstrumentRow
        .filter(InstrumentRow.Columns.encodedSystemFields == nil)
        .filter(InstrumentRow.Columns.kind != fiatKind)
        .select(InstrumentRow.Columns.id, as: String.self)
        .fetchAll(database)
    }
  }

  /// Projects an `InstrumentRow` to a `CryptoRegistration`, applying the
  /// inbox / spam visibility rules:
  ///
  /// - Rows with a recorded provider mapping return a registration with
  ///   that mapping (regardless of status).
  /// - Rows with no provider mapping but a non-`.priced` status (i.e.
  ///   the discovery actor's `.unpriced` / `.spam` writes) return a
  ///   registration with an all-nil mapping so the Discovered Tokens
  ///   inbox + Spam Tokens management UI can render and act on them,
  ///   and so the discovery actor's "is this row already registered?"
  ///   fast path does not re-resolve them every cycle.
  /// - Rows with no provider mapping AND default `.priced` status are
  ///   legacy CSV-import placeholders (`ensureInstrument` auto-inserts
  ///   from before the user resolved a mapping) and project to `nil`.
  static func project(row: InstrumentRow) throws -> CryptoRegistration? {
    let status =
      TokenPricingStatus(rawValue: row.pricingStatus) ?? .priced
    let mapping = row.cryptoMapping()
    guard mapping != nil || status != .priced else { return nil }
    return CryptoRegistration(
      instrument: try row.toDomain(),
      mapping: mapping ?? row.emptyCryptoMapping(),
      pricingStatus: status)
  }
}
