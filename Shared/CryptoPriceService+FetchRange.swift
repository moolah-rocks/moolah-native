// Shared/CryptoPriceService+FetchRange.swift

import Foundation

// MARK: - CryptoPriceService provider fallback

extension CryptoPriceService {
  /// Runs the provider fallback chain
  /// (CoinGecko → CryptoCompare → Binance) for the date enclosed by
  /// `dateString`, persists any new prices, and returns the requested
  /// day's value (or the prior-trading-day fallback). Throws a
  /// `WalletSyncError` attributed to the most recent *real* provider
  /// failure when no provider could fill the date — `noProviderMapping`
  /// errors are routing decisions (e.g. USDT has no Binance pair), not
  /// runtime failures, so they never become the attribution.
  func fetchAndExtendCache(
    instrument: Instrument,
    mapping: CryptoProviderMapping,
    fetchInterval: ClosedRange<Date>,
    dateString: String
  ) async throws -> Decimal {
    let tokenId = instrument.id
    let symbol = instrument.ticker ?? instrument.name
    var lastError: (any Error)?
    var lastProvider: SyncProvider?
    for client in clients {
      do {
        let fetched = try await client.dailyPrices(for: mapping, in: fetchInterval)
        if !fetched.isEmpty {
          let delta = mergeReturningDelta(
            tokenId: tokenId, symbol: symbol, newPrices: fetched)
          if !delta.isEmpty {
            try await persistDelta(tokenId: tokenId, deltaRecords: delta)
          }
          if let price = lookupPrice(tokenId: tokenId, dateString: dateString) {
            return price
          }
        }
      } catch CryptoPriceError.noProviderMapping {
        // Routing decision — this client has no symbol for the token
        // (e.g. USDT on Binance). Skip silently rather than attributing
        // a non-existent outage to a provider that's behaving as designed.
        continue
      } catch {
        lastError = error
        lastProvider = client.syncProvider
        continue
      }
    }
    if let fallback = fallbackPrice(tokenId: tokenId, dateString: dateString) {
      return fallback
    }
    let underlyingDescription =
      lastError.map { String(describing: $0) }
      ?? String(
        describing: CryptoPriceError.noPriceAvailable(
          tokenId: tokenId, date: dateString))
    throw WalletSyncError(
      provider: lastProvider,
      kind: .network(underlyingDescription: underlyingDescription))
  }

  /// Runs the provider fallback chain
  /// (CoinGecko → CryptoCompare → Binance) for a date range, tolerating
  /// per-provider failures and only throwing when every client errored.
  /// It is `internal` (not `private`) because it is called from
  /// `prices(for:mapping:in:)` in `CryptoPriceService.swift`; it remains
  /// actor-isolated.
  func fetchRange(
    instrument: Instrument, mapping: CryptoProviderMapping, from: Date, to: Date
  ) async throws {
    let tokenId = instrument.id
    let symbol = instrument.ticker ?? instrument.name
    var lastError: (any Error)?
    var lastProvider: SyncProvider?
    for client in clients {
      do {
        let fetched = try await client.dailyPrices(for: mapping, in: from...to)
        if !fetched.isEmpty {
          let delta = mergeReturningDelta(
            tokenId: tokenId, symbol: symbol, newPrices: fetched)
          if !delta.isEmpty {
            try await persistDelta(tokenId: tokenId, deltaRecords: delta)
          }
          return
        }
      } catch CryptoPriceError.noProviderMapping {
        // Routing decision — this client has no symbol for the token
        // (e.g. USDT on Binance). Skip silently rather than attributing
        // a non-existent outage to a provider that's behaving as designed.
        continue
      } catch {
        lastError = error
        lastProvider = client.syncProvider
        continue
      }
    }
    if let error = lastError {
      throw WalletSyncError(
        provider: lastProvider,
        kind: .network(underlyingDescription: String(describing: error)))
    }
  }
}
