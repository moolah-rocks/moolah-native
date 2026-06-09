// MoolahTests/Support/ToggleableCryptoPriceClient.swift
import Foundation

@testable import Moolah

/// Test double whose responses can be flipped at runtime. Backed by an
/// `actor` so concurrent reads / writes from the conversion-service /
/// price-warmer pipelines stay race-free without any `@unchecked Sendable`
/// waiver. When failing it throws a configurable error (defaulting to a
/// generic network error); otherwise it serves the stored prices, walking
/// the requested range the same way `FixedCryptoPriceClient` does.
actor ToggleableCryptoPriceClient: CryptoPriceClient {
  nonisolated let syncProvider: SyncProvider

  private var prices: [String: [String: Decimal]] = [:]
  private var shouldFail = false
  private var failureError: any Error = URLError(.notConnectedToInternet)

  init(syncProvider: SyncProvider = .binance) {
    self.syncProvider = syncProvider
  }

  func setPrices(_ prices: [String: [String: Decimal]]) {
    self.prices = prices
  }

  /// Flip the failure flag, optionally supplying the error to throw. When
  /// `error` is `nil` while failing, a generic network error is used.
  func setShouldFail(_ fail: Bool, error: (any Error)? = nil) {
    self.shouldFail = fail
    if let error {
      self.failureError = error
    }
  }

  func dailyPrice(for mapping: CryptoProviderMapping, on date: Date) async throws -> Decimal {
    if shouldFail { throw failureError }
    let dateString = dateFormatter.string(from: date)
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
      let key = dateFormatter.string(from: current)
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

  /// Actor-isolated (not `static`) so the non-`Sendable` formatter is
  /// confined to this actor and needs no concurrency annotation.
  private let dateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return formatter
  }()
}
