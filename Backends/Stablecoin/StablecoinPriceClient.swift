import Foundation

/// Last-resort price source that reports a flat USD $1 for canonical USDC /
/// USDT deployments. Stablecoins track their peg, so when every market-data
/// provider declines a recognised stablecoin (e.g. an L2 USDC that the
/// upstream price providers don't index or rate-limit), the peg is a safe
/// fallback rather than leaving the token unpriced.
///
/// Membership is gated through `CanonicalTokenRegistry`, which only recognises
/// the *legitimate* deployment addresses for each protected symbol — so a
/// look-alike token reusing the "USDC" symbol at a different address yields no
/// peg. The client declines everything it does not recognise by throwing
/// `.noProviderMapping`, so the price service skips it silently and the next
/// provider (none — this is last) is consulted exactly as for any other client
/// without a symbol for the token.
struct StablecoinPriceClient: CryptoPriceClient, Sendable {
  /// The set of canonical symbols this client treats as $1-pegged.
  private static let peggedSymbols: Set<String> = ["USDC", "USDT"]

  var syncProvider: SyncProvider { .peggedStablecoin }

  func dailyPrice(for mapping: CryptoProviderMapping, on date: Date) async throws -> Decimal {
    let prices = try await dailyPrices(for: mapping, in: date...date)
    let key = date.iso8601DateOnlyString
    guard let price = prices[key] else {
      throw CryptoPriceError.noPriceAvailable(tokenId: mapping.instrumentId, date: key)
    }
    return price
  }

  func dailyPrices(
    for mapping: CryptoProviderMapping, in range: ClosedRange<Date>
  ) async throws -> [String: Decimal] {
    guard Self.isPegged(mapping.instrumentId) else {
      throw CryptoPriceError.noProviderMapping(
        tokenId: mapping.instrumentId, provider: "Stablecoin peg")
    }
    var result: [String: Decimal] = [:]
    var current = range.lowerBound
    while current <= range.upperBound {
      result[current.iso8601DateOnlyString] = Decimal(1)
      guard let next = Calendar.utc.date(byAdding: .day, value: 1, to: current) else { break }
      current = next
    }
    return result
  }

  func currentPrices(for mappings: [CryptoProviderMapping]) async throws -> [String: Decimal] {
    var result: [String: Decimal] = [:]
    for mapping in mappings where Self.isPegged(mapping.instrumentId) {
      result[mapping.instrumentId] = Decimal(1)
    }
    return result
  }

  /// `true` when `instrumentId` ("<chainId>:<address>") names a canonical USDC
  /// or USDT deployment. Native ids ("<chainId>:native") and non-canonical /
  /// look-alike addresses return `false`.
  private static func isPegged(_ instrumentId: String) -> Bool {
    guard let separator = instrumentId.firstIndex(of: ":") else { return false }
    let chainPart = instrumentId[..<separator]
    let addressPart = instrumentId[instrumentId.index(after: separator)...]
    guard let chainId = Int(chainPart), addressPart != "native" else { return false }
    guard
      let symbol = CanonicalTokenRegistry.symbol(
        chainId: chainId, contractAddress: String(addressPart))
    else { return false }
    return peggedSymbols.contains(symbol)
  }
}
