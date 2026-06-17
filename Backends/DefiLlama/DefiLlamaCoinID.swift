import Foundation

/// Derives a DefiLlama coins-API identifier from a Moolah crypto
/// `instrumentId`. ERC-20 tokens resolve to `{chain}:{address}` using the
/// contract address already encoded in the id; native coins (no contract)
/// resolve to `coingecko:{id}`. Pure and side-effect-free.
enum DefiLlamaCoinID {
  /// DefiLlama chain slugs by EVM chain id. Bitcoin (chain 0) is intentionally
  /// absent: BTC is a native coin and resolves via `coingecko:bitcoin`.
  private static let chainSlugs: [Int: String] = [
    1: "ethereum",
    10: "optimism",
    137: "polygon",
    8453: "base",
    42161: "arbitrum",
    43114: "avax",
    534352: "scroll",
  ]

  /// Returns the DefiLlama coin id, or `nil` when the token cannot be addressed
  /// (unknown chain for an ERC-20, or a native coin with no coingecko id).
  static func make(instrumentId: String, coingeckoId: String?) -> String? {
    let parts = instrumentId.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2, let chainId = Int(parts[0]) else { return nil }
    let suffix = parts[1]
    if suffix == "native" {
      guard let coingeckoId, !coingeckoId.isEmpty else { return nil }
      return "coingecko:\(coingeckoId)"
    }
    guard let slug = chainSlugs[chainId] else { return nil }
    return "\(slug):\(suffix)"
  }
}
