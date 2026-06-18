// Domain/Repositories/CryptoPriceClient.swift
import Foundation

enum CryptoPriceError: Error, Equatable {
  case noPriceAvailable(tokenId: String, date: String)
  case noProviderMapping(tokenId: String, provider: String)
  case allProvidersFailed(tokenId: String)
  /// Thrown when the requested date is strictly before the token's confirmed
  /// first-trade date. The token had no market price on this date; callers
  /// should treat the holding as worth $0 (ATO-correct for pre-listing airdrops).
  case beforeFirstTrade(tokenId: String, date: String)
}

extension CryptoPriceError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case let .noPriceAvailable(tokenId, date):
      return "No price available for \(tokenId) on \(date)."
    case let .noProviderMapping(tokenId, provider):
      return "No price source is configured for \(tokenId) (provider: \(provider))."
    case let .allProvidersFailed(tokenId):
      return "Unable to fetch a price for \(tokenId) from any source."
    case let .beforeFirstTrade(tokenId, date):
      return "\(tokenId) had not yet started trading on \(date); valued at $0."
    }
  }
}

/// Abstraction for fetching cryptocurrency prices from an external source.
/// Implementations: CryptoCompareClient (default), BinanceClient (fallback), CoinGeckoClient (premium).
/// All prices are denominated in USD.
protocol CryptoPriceClient: Sendable {
  /// Which provider this client represents, used to attribute a
  /// total-price-failure error to the last provider attempted.
  var syncProvider: SyncProvider { get }

  /// Fetch the daily closing price for a token in USD on a specific date.
  func dailyPrice(for mapping: CryptoProviderMapping, on date: Date) async throws -> Decimal

  /// Fetch daily closing prices for a token in USD over a date range.
  /// Returns prices keyed by ISO date string for each available trading day.
  func dailyPrices(for mapping: CryptoProviderMapping, in range: ClosedRange<Date>) async throws
    -> [String: Decimal]

  /// Fetch current prices for multiple tokens in a single request (where supported).
  /// Returns prices keyed by instrument ID.
  func currentPrices(for mappings: [CryptoProviderMapping]) async throws -> [String: Decimal]
}
