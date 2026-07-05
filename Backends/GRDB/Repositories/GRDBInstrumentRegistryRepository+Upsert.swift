// Backends/GRDB/Repositories/GRDBInstrumentRegistryRepository+Upsert.swift

import Foundation
import GRDB

// Row-level upsert helpers for `GRDBInstrumentRegistryRepository`. They
// live in a sibling extension file so the primary file stays under
// SwiftLint's `file_length` budget. They are `static` and module-scoped
// (default `internal`) so the primary type's `register…` methods can call
// `Self.upsertCrypto` / `Self.upsertStock`, and `applyRemoteChangesSync`
// can call `Self.clearDeletionIntent`, across the same-module extension
// boundary — mirroring the `+SyncHooks` / `+Lookup` split.
extension GRDBInstrumentRegistryRepository {
  /// Inserts a new crypto row or updates the existing one in-place,
  /// preserving `recordName` and `encodedSystemFields`. Mirrors
  /// `CloudKitInstrumentRegistryRepository.upsertCrypto`.
  ///
  /// When `forcingStatus` is non-nil the row's `pricingStatus` is set to
  /// that value in the same write; when nil an existing row keeps its
  /// stored status and an insert takes the column default (`.priced`).
  /// The forcing path lets `registerCrypto(_:mapping:forcingStatus:)`
  /// land the mapping and a freshly-computed status in one transaction so
  /// the sync-queue hook fires exactly once against the final state
  /// (issue #895).
  ///
  /// The two branches apply the forced status differently: the
  /// existing-row branch sets it *after* `mergeResolvedFields`, which is
  /// safe only because that helper deliberately never writes
  /// `pricingStatus`; the insert branch sets it during row construction,
  /// overriding `InstrumentRow(domain:)`'s `.priced` column default
  /// before the first `INSERT`.
  static func upsertCrypto(
    database: Database,
    instrument: Instrument,
    mapping: CryptoProviderMapping,
    forcingStatus status: TokenPricingStatus? = nil
  ) throws {
    if var existing =
      try InstrumentRow
      .filter(InstrumentRow.Columns.id == instrument.id)
      .fetchOne(database)
    {
      mergeResolvedFields(into: &existing, from: instrument, mapping: mapping)
      if let status { existing.pricingStatus = status.rawValue }
      try existing.update(database)
    } else {
      var row = InstrumentRow(domain: instrument)
      row.coingeckoId = mapping.coingeckoId
      row.binanceSymbol = mapping.binanceSymbol
      if let status { row.pricingStatus = status.rawValue }
      try row.insert(database)
    }
    try clearDeletionIntent(for: instrument.id, in: database)
  }

  /// Upgrade-only field merge: a nil/empty incoming column must never
  /// downgrade a populated stored column.
  ///
  /// A thin ensureInstrument-style publish carries all-nil / empty identity
  /// fields; allowing it to overwrite would destroy a richer
  /// discovery-resolved row (e.g. Trust Wallet's ensureInstrument for
  /// Ethereum clobbering the coingecko-resolved ticker/exchange). Every
  /// identity column therefore requires a non-empty / non-zero incoming
  /// value before overwriting; `kind` and `decimals` are always
  /// authoritative and are updated unconditionally.
  ///
  /// Provider mapping columns are also merged: a nil incoming column must
  /// not downgrade a populated stored column. See the shared-registry
  /// clobber bug (Trust - Ethereum 1:native).
  private static func mergeResolvedFields(
    into existing: inout InstrumentRow,
    from instrument: Instrument,
    mapping: CryptoProviderMapping
  ) {
    existing.kind = instrument.kind.rawValue
    if !instrument.name.isEmpty { existing.name = instrument.name }
    existing.decimals = instrument.decimals
    if let ticker = instrument.ticker, !ticker.isEmpty { existing.ticker = ticker }
    if let exchange = instrument.exchange, !exchange.isEmpty { existing.exchange = exchange }
    if let chainId = instrument.chainId, chainId != 0 { existing.chainId = chainId }
    if let contractAddress = instrument.contractAddress, !contractAddress.isEmpty {
      existing.contractAddress = contractAddress
    }
    existing.coingeckoId = mapping.coingeckoId ?? existing.coingeckoId
    existing.binanceSymbol = mapping.binanceSymbol ?? existing.binanceSymbol
  }

  /// Inserts a new stock row or updates the existing one in-place. Stock
  /// upserts never touch the provider-mapping columns — they are written
  /// only by `registerCrypto`. Mirrors
  /// `CloudKitInstrumentRegistryRepository.upsertStock`.
  static func upsertStock(
    database: Database,
    instrument: Instrument
  ) throws {
    if var existing =
      try InstrumentRow
      .filter(InstrumentRow.Columns.id == instrument.id)
      .fetchOne(database)
    {
      existing.kind = instrument.kind.rawValue
      existing.name = instrument.name
      existing.decimals = instrument.decimals
      existing.ticker = instrument.ticker
      existing.exchange = instrument.exchange
      try existing.update(database)
    } else {
      let row = InstrumentRow(domain: instrument)
      try row.insert(database)
    }
    try clearDeletionIntent(for: instrument.id, in: database)
  }

  /// Drops any stale durable deletion intent for `id` in the caller's write
  /// transaction (D1-b, issue #1097), symmetric with `ProfileRow`'s clear in
  /// `upsert` and `Category`'s in `create`: a delete-then-re-register nets zero
  /// tombstone, so a start-time replay can never delete the live re-created
  /// instrument. The intent is keyed by the `profile-index` zone (the bare
  /// instrument id is its CloudKit recordName). Idempotent. MUST be called from
  /// inside an existing `database.write { db in … }` closure (it takes the
  /// `Database` token, so it runs on the GRDB writer's serial queue).
  static func clearDeletionIntent(for id: String, in database: Database) throws {
    try DeletionJournal.clear(
      zoneName: DeletionJournal.profileIndexZoneName,
      recordName: InstrumentRow.recordName(for: id),
      in: database)
  }
}
