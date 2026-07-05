// Backends/GRDB/Repositories/GRDBInstrumentRegistryRepository+InstrumentRegistering.swift

import GRDB

extension GRDBInstrumentRegistryRepository: InstrumentRegistering {
  /// Registers a non-fiat instrument into the canonical (profile-index)
  /// registry so the production resolver — this same repository's
  /// `instrumentMap()` — resolves it on the very next read. Awaited by
  /// the create / update paths before their per-profile write, replacing
  /// the old per-profile placeholder `instrument` insert.
  ///
  /// Fiat is ambient and never stored. Stocks go through `registerStock`;
  /// crypto goes through `registerCrypto` with an *empty* provider
  /// mapping. The empty mapping is safe: `upsertCrypto`'s
  /// `mergeResolvedFields` is upgrade-only — a nil/empty incoming column
  /// never downgrades a populated stored one — so a brand-new id inserts
  /// as priced/no-mapping (exactly as the old placeholder did, where the
  /// discovery service's `resolveOrLoad` later enriches it), while a
  /// redundant call for an already-resolved instrument is a no-op merge.
  /// Both register methods additionally invalidate the instrument-map
  /// cache and fire the sync fan-out, so the registered row reaches
  /// CloudKit and propagates to sibling devices.
  func registerResolvable(_ instrument: Instrument) async throws {
    switch instrument.kind {
    case .fiatCurrency:
      // Ambient — synthesised from `Locale.Currency.isoCurrencies` in
      // `fetchInstrumentMap`; never stored.
      return
    case .stock:
      try await registerStock(instrument)
    case .cryptoToken:
      try await registerCrypto(
        instrument,
        mapping: CryptoProviderMapping(
          instrumentId: instrument.id,
          coingeckoId: nil,
          binanceSymbol: nil))
    }
  }
}
