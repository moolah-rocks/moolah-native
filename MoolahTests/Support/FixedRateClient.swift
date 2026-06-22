// MoolahTests/Support/FixedRateClient.swift
import Foundation

@testable import Moolah

/// Test double that returns pre-configured rates without network calls.
struct FixedRateClient: ExchangeRateClient, Sendable {
  /// Pre-loaded rates: date string -> { quote currency code -> rate }
  let rates: [String: [String: Decimal]]

  /// If true, throws on any fetch call (simulates network failure).
  let shouldFail: Bool

  init(rates: [String: [String: Decimal]] = [:], shouldFail: Bool = false) {
    self.rates = rates
    self.shouldFail = shouldFail
  }

  func fetchRates(base: String, from: Date, to: Date) async throws -> [String: [String: Decimal]] {
    if shouldFail {
      throw URLError(.notConnectedToInternet)
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    formatter.timeZone = TimeZone(identifier: "UTC") ?? .current

    var result: [String: [String: Decimal]] = [:]
    var current = from
    while current <= to {
      let key = formatter.string(from: current)
      if let dayRates = rates[key] {
        result[key] = dayRates
      }
      guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
      current = next
    }
    return result
  }
}
