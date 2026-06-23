import Foundation
import GRDB

// MARK: - CryptoPriceService SQL persistence

// SQL persistence for `CryptoPriceService`.

extension CryptoPriceService {
  /// Hydrates `caches[tokenId]` from `crypto_price` + `crypto_token_meta`.
  /// The meta row's `symbol` is display-only — used to populate
  /// `CryptoPriceCache.symbol` on the way back; not used for lookups.
  ///
  /// Marks the token id as hydrated even when no rows exist so we don't
  /// re-query on every miss.
  func loadCache(tokenId: String) async throws {
    let snapshot: CryptoPriceCache? = try await database.read { database in
      let metaRecord =
        try CryptoTokenMetaRecord
        .filter(CryptoTokenMetaRecord.Columns.tokenId == tokenId)
        .fetchOne(database)
      guard let metaRecord else { return nil }
      let priceRecords =
        try CryptoPriceRecord
        .filter(CryptoPriceRecord.Columns.tokenId == tokenId)
        .order(CryptoPriceRecord.Columns.date)
        .fetchAll(database)
      // See `ExchangeRateService.loadCache` for the rationale on the
      // String-via-Decimal round-trip; preserves source precision instead
      // of inheriting the binary `Decimal(_: Double)` tail.
      // `.order(date)` ascending satisfies `init(sortedEntries:)`.
      var entries: [SortedDateSeries<Decimal>.Entry] = []
      entries.reserveCapacity(priceRecords.count)
      for record in priceRecords {
        guard let key = DateKey.from(isoString: record.date) else { continue }  // malformed wire date — unusable as a sorted key; skip
        let value = Decimal(string: String(record.priceUsd)) ?? Decimal(record.priceUsd)
        entries.append(.init(key: key, value: value))
      }
      return CryptoPriceCache(
        tokenId: tokenId,
        symbol: metaRecord.symbol,
        earliestDate: metaRecord.earliestDate,
        latestDate: metaRecord.latestDate,
        prices: SortedDateSeries(sortedEntries: entries),
        firstTradedOn: metaRecord.firstTradedOn
      )
    }
    if let snapshot { caches[tokenId] = snapshot }
    hydrated.insert(tokenId)
  }

  /// Writes the confirmed first-trade date to the `crypto_token_meta` row for
  /// `tokenId`, carrying the existing symbol, earliest, and latest from cache
  /// so the `INSERT OR REPLACE` does not clobber them.
  ///
  /// `persistFirstTradedOn` is separate from `persistDelta` to avoid the cost
  /// of a redundant meta write on every delta flush: it runs only once, after
  /// the backward walk exhaustion. Callers must have already updated
  /// `caches[tokenId].firstTradedOn` before calling this.
  func persistFirstTradedOn(tokenId: String, date: String) async throws {
    guard let cache = caches[tokenId] else { return }
    let meta = CryptoTokenMetaRecord(
      tokenId: tokenId,
      symbol: cache.symbol,
      earliestDate: cache.earliestDate,
      latestDate: cache.latestDate,
      firstTradedOn: date
    )
    try await database.write { database in
      try meta.insert(database, onConflict: .replace)
      try database.notifyRateCacheChange(.cryptoPrice)
    }
  }

  /// Persists the rows produced by `mergeReturningDelta` for `tokenId`
  /// plus the latest meta-bounds, all in a single transaction.
  ///
  /// Each delta row is written `INSERT OR REPLACE`; the meta row is
  /// `INSERT OR REPLACE`d via `CryptoTokenMetaRecord`'s `.replace`
  /// conflict policy. There is no `deleteAll` — historic prices never
  /// change, and rewriting the whole token on every fetch saturated the
  /// GRDB queue. The rollback contract still holds because every
  /// statement runs inside one `database.write` closure and any failure
  /// rolls them back together.
  ///
  /// Captures `caches[tokenId]` before suspending on `database.write`.
  /// Actor re-entrancy is acceptable here: a concurrent merge will
  /// produce its own delta with its own `persistDelta` afterwards, so
  /// the disk converges to the latest in-memory state. A crash between
  /// two writes leaves the disk at an intermediate-but-consistent
  /// snapshot — acceptable for a best-effort persistent cache.
  func persistDelta(tokenId: String, deltaRecords: [CryptoPriceRecord]) async throws {
    guard let cache = caches[tokenId] else { return }
    let meta = CryptoTokenMetaRecord(
      tokenId: tokenId,
      symbol: cache.symbol,
      earliestDate: cache.earliestDate,
      latestDate: cache.latestDate,
      firstTradedOn: cache.firstTradedOn
    )
    try await database.write { database in
      // GRDB caches the insert statement internally; no explicit cachedStatement needed.
      for record in deltaRecords {
        try record.insert(database, onConflict: .replace)
      }
      try meta.insert(database, onConflict: .replace)
      // `crypto_price` is `WITHOUT ROWID`; SQLite's update hook does
      // not fire for these tables, so `ValueObservation` over the
      // rate-cache region needs an explicit notify to see this write.
      // See `Backends/GRDB/Observation/RateCacheTable.swift`
      // and `guides/DATABASE_CODE_GUIDE.md` §2 convention 1.
      try database.notifyRateCacheChange(.cryptoPrice)
    }
  }
}
