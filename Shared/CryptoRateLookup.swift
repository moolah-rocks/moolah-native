import Foundation
import OSLog

/// Resolves a single USD rate for a token by trying an ordered list of price
/// clients and returning the first that succeeds, skipping any that throws.
///
/// Used to price the Binance USDT/USD conversion rate through the same
/// provider precedence the main price chain uses, ending in
/// `StablecoinPriceClient`. That way a CoinGecko outage falls through to
/// Binance's real USDT price before assuming parity, and the $1 last resort
/// comes from the single canonical peg source rather than a literal at the
/// call site. The `default` is a final safety net only — for a canonical
/// stablecoin the peg always answers, so it is unreachable in practice; a
/// `warning` is logged if it ever fires (every provider, including the peg,
/// declined the token — a misconfiguration worth surfacing).
enum CryptoRateLookup {
  private static let logger = Logger(
    subsystem: "com.moolah.app", category: "CryptoRateLookup")

  static func firstAvailableRate(
    for mapping: CryptoProviderMapping,
    on date: Date,
    using clients: [CryptoPriceClient],
    default fallback: Decimal
  ) async -> Decimal {
    for client in clients {
      do {
        return try await client.dailyPrice(for: mapping, on: date)
      } catch {
        logger.debug(
          "rate: \(client.syncProvider.displayName, privacy: .public) declined \(mapping.instrumentId, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
      }
    }
    logger.warning(
      "rate: every provider declined \(mapping.instrumentId, privacy: .public); using default \(fallback.description, privacy: .public)"
    )
    return fallback
  }
}
