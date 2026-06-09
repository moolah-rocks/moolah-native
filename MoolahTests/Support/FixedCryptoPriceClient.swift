// MoolahTests/Support/FixedCryptoPriceClient.swift
import Foundation

@testable import Moolah

/// Test double that returns pre-configured crypto prices without network calls.
struct FixedCryptoPriceClient: CryptoPriceClient, Sendable {
  /// Pre-loaded prices: instrument ID -> { date string -> price in USD }
  let prices: [String: [String: Decimal]]

  /// If true, throws on any fetch call (simulates network failure).
  let shouldFail: Bool

  /// Specific error to throw when `shouldFail` is true. Defaults to a
  /// network error so existing tests retain their behaviour; provider-
  /// attribution tests pass `CryptoPriceError.noProviderMapping` to model
  /// a client that legitimately has no symbol for the token (e.g. USDT
  /// on Binance).
  let failureError: any Error

  /// Provider identity this stub reports — lets attribution tests order
  /// stubs so a known provider is last in the fallback chain.
  let syncProvider: SyncProvider

  init(
    prices: [String: [String: Decimal]] = [:],
    shouldFail: Bool = false,
    failureError: (any Error)? = nil,
    syncProvider: SyncProvider = .coinGecko
  ) {
    self.prices = prices
    self.shouldFail = shouldFail
    self.failureError = failureError ?? URLError(.notConnectedToInternet)
    self.syncProvider = syncProvider
  }

  func dailyPrice(for mapping: CryptoProviderMapping, on date: Date) async throws -> Decimal {
    if shouldFail { throw failureError }
    let dateString = Self.dateFormatter.string(from: date)
    guard let price = prices[mapping.instrumentId]?[dateString] else {
      throw CryptoPriceError.noPriceAvailable(tokenId: mapping.instrumentId, date: dateString)
    }
    return price
  }

  func dailyPrices(
    for mapping: CryptoProviderMapping, in range: ClosedRange<Date>
  ) async throws -> [String: Decimal] {
    if shouldFail { throw failureError }
    guard let tokenPrices = prices[mapping.instrumentId] else { return [:] }

    let calendar = Calendar(identifier: .gregorian)
    var filtered: [String: Decimal] = [:]
    var current = range.lowerBound
    while current <= range.upperBound {
      let key = Self.dateFormatter.string(from: current)
      if let price = tokenPrices[key] {
        filtered[key] = price
      }
      guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
      current = next
    }
    return filtered
  }

  func currentPrices(for mappings: [CryptoProviderMapping]) async throws -> [String: Decimal] {
    if shouldFail { throw failureError }
    var result: [String: Decimal] = [:]
    for mapping in mappings {
      if let tokenPrices = prices[mapping.instrumentId],
        let latest = tokenPrices.keys.max()
      {
        result[mapping.instrumentId] = tokenPrices[latest]
      }
    }
    return result
  }

  // Write-once after init and only ever read (formatting) — never mutated
  // — so the shared static is safe. `ISO8601DateFormatter` is not
  // `Sendable`, and this `struct` is `Sendable`, so an instance `let`
  // would break the conformance; `nonisolated(unsafe)` is the correct
  // annotation for an immutable shared static of a non-`Sendable` type.
  nonisolated(unsafe) private static let dateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return formatter
  }()
}
