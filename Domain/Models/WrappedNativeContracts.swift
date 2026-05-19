import Foundation

/// Curated trust list of canonical *wrapped-native* token contracts
/// (WETH, WMATIC, WAVAX, …) that are, by their official deployment,
/// 1:1 redeemable for their chain's native asset.
///
/// Wrapped-native tokens have no third-party price feed of their own
/// (no CoinGecko/CryptoCompare/Binance id), so without this they fail
/// to price entirely — surfacing on the Analysis page as a sync error.
/// They are economically identical to the native asset, so we price
/// them as that chain's native instrument (`"<chainId>:native"`),
/// reusing the native asset's working price feed.
///
/// **Trust model — exact `(chainId, address)` only.** Matching is on a
/// hand-verified `(chainId, lowercased contractAddress)` pair, *never*
/// on symbol or name. A token that merely calls itself "WETH" must not
/// inherit the native asset's price: it could be a malicious look-alike
/// that never returns the underlying ETH. The same logical asset has
/// different contract addresses on different chains, and a chain can
/// host multiple "WETH"-named contracts; only the canonical official
/// deployment for a given chain is listed here. Adding an entry is a
/// deliberate trust decision — verify the address against the chain's
/// official documentation before extending this map.
enum WrappedNativeContracts {
  /// Canonical wrapped-native contract address (lowercased) per chain.
  /// Each maps the wrapped token to its chain's native asset, which is
  /// priced via the normal native registration.
  private static let canonicalByChain: [Int: String] = [
    // Ethereum — WETH
    1: "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",
    // Optimism — WETH (network predeploy)
    10: "0x4200000000000000000000000000000000000006",
    // Base — WETH (network predeploy)
    8453: "0x4200000000000000000000000000000000000006",
    // Arbitrum One — WETH
    42161: "0x82af49447d8a07e3bd95bd0d56f35241523fbab1",
    // Polygon — WMATIC
    137: "0x0d500b1d8e8ef31e21c99d1db9a6444d3adf1270",
    // Avalanche C-Chain — WAVAX
    43114: "0xb31f66aa3c1e785363f0875a1b74e27b85fd66c7",
  ]

  /// If `(chainId, contractAddress)` is the canonical wrapped-native
  /// contract for that chain, returns the chain's native instrument id
  /// (`"<chainId>:native"`) so the caller can price the wrapped token
  /// as the native asset. Returns `nil` for native instruments (no
  /// contract address), unknown contracts, and right-address/wrong-chain
  /// queries — the caller then prices the token normally.
  static func nativePricingInstrumentId(
    chainId: Int?, contractAddress: String?
  ) -> String? {
    guard let chainId,
      let contractAddress,
      let canonical = canonicalByChain[chainId],
      contractAddress.lowercased() == canonical
    else {
      return nil
    }
    return "\(chainId):native"
  }

  /// Inverse of `nativePricingInstrumentId`: the canonical wrapped-native
  /// instrument id for a chain (`"<chainId>:<address>"`), or `nil` when
  /// the chain has no listed wrapper. A wrapped token is priced via the
  /// chain's native asset but its conversion rate is memoised under the
  /// *wrapper's* own id, so cache invalidation for the native asset must
  /// also evict the wrapper — this accessor gives the id to evict.
  static func canonicalWrappedInstrumentId(forChainId chainId: Int?) -> String? {
    guard let chainId, let address = canonicalByChain[chainId] else { return nil }
    return "\(chainId):\(address)"
  }
}
