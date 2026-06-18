// Domain/Models/CryptoPriceCache.swift
import Foundation

/// On-disk cache for a single crypto token. Contains daily closing prices in USD.
struct CryptoPriceCache: Codable, Sendable, Equatable {
  let tokenId: String  // e.g. "1:native"
  let symbol: String  // e.g. "ETH" — display only
  var earliestDate: String  // ISO date string "YYYY-MM-DD"
  var latestDate: String  // ISO date string "YYYY-MM-DD"
  var prices: SortedDateSeries<Decimal>  // DateKey -> daily closing price in USD
  /// Confirmed cross-provider first-trade date (`YYYY-MM-DD`).
  /// `nil` means the date has not yet been confirmed.
  var firstTradedOn: String?
}
