import Foundation

/// Curated trust list of canonical *wrapped-native* token contracts
/// (WETH, WMATIC, WAVAX, …) that are, by their official deployment,
/// 1:1 redeemable for their chain's native asset.
///
/// Wrapped-native tokens have no third-party price feed of their own
/// (no CoinGecko/Binance id), so without this they fail
/// to price entirely — surfacing on the Analysis page as a sync error.
/// They are economically identical to the native asset, so we price
/// them via a canonical native instrument id, reusing that native
/// asset's working price feed.
///
/// **L2 ETH wrappers:** OP and Base WETH price via the *mainnet* ETH
/// canonical id (`1:native`), not their chain's own `"<chainId>:native"` id,
/// which is a retired alias now that OP/Base ETH is unified to `1:native`.
/// Arbitrum WETH is not yet unified and still prices via `42161:native`.
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
  /// Wrapped-native contract address (lowercased) + the canonical native
  /// instrument id it prices via. L2 ETH wrappers (OP, Base) price via
  /// mainnet ETH (`1:native`); non-unified chains price via their own native.
  private static let entries: [Int: (address: String, nativeId: String)] = [
    // Ethereum — WETH
    1: ("0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2", "1:native"),
    // Optimism — WETH (network predeploy) → prices via mainnet ETH
    10: ("0x4200000000000000000000000000000000000006", "1:native"),
    // Base — WETH (network predeploy) → prices via mainnet ETH
    8453: ("0x4200000000000000000000000000000000000006", "1:native"),
    // Arbitrum One — WETH (not yet unified; prices via its own chain native)
    42161: ("0x82af49447d8a07e3bd95bd0d56f35241523fbab1", "42161:native"),
    // Polygon — WMATIC
    137: ("0x0d500b1d8e8ef31e21c99d1db9a6444d3adf1270", "137:native"),
    // Avalanche C-Chain — WAVAX
    43114: ("0xb31f66aa3c1e785363f0875a1b74e27b85fd66c7", "43114:native"),
  ]

  /// If `(chainId, contractAddress)` is the canonical wrapped-native
  /// contract for that chain, returns the canonical native instrument id
  /// to use for pricing. For L2 ETH chains (OP, Base) this is `"1:native"`
  /// (unified to mainnet ETH); for other chains it is `"<chainId>:native"`.
  /// Returns `nil` for native instruments (no contract address), unknown
  /// contracts, and right-address/wrong-chain queries — the caller then
  /// prices the token normally.
  static func nativePricingInstrumentId(
    chainId: Int?, contractAddress: String?
  ) -> String? {
    guard let chainId,
      let contractAddress,
      let entry = entries[chainId],
      contractAddress.lowercased() == entry.address
    else {
      return nil
    }
    return entry.nativeId
  }

  /// Every listed wrapper id (`"<chainId>:<address>"`) that prices via
  /// `nativeId`. Used by cache invalidation: dropping a native rate must
  /// also evict all wrappers memoised under their own id (OP and Base WETH
  /// price via the same `1:native` as mainnet WETH).
  ///
  /// For `"1:native"` this returns mainnet WETH + OP WETH + Base WETH;
  /// for `"137:native"` it returns only WMATIC.
  static func wrapperIds(pricingVia nativeId: String) -> [String] {
    entries.compactMap { chainId, entry in
      entry.nativeId == nativeId ? "\(chainId):\(entry.address)" : nil
    }
  }

  /// Inverse of `nativePricingInstrumentId`: the canonical wrapped-native
  /// instrument id for a chain (`"<chainId>:<address>"`), or `nil` when
  /// the chain has no listed wrapper. A wrapped token is priced via the
  /// native asset but its conversion rate is memoised under the
  /// *wrapper's* own id, so cache invalidation for the native asset must
  /// also evict the wrapper — this accessor gives the id to evict.
  ///
  /// Used by `CryptoPriceService.purgeCache` to evict the metadata-cache
  /// entry for a single chain's wrapper when the native id is purged.
  /// For multi-wrapper eviction (OP + Base WETH) use `wrapperIds(pricingVia:)`.
  static func canonicalWrappedInstrumentId(forChainId chainId: Int?) -> String? {
    guard let chainId, let entry = entries[chainId] else { return nil }
    return "\(chainId):\(entry.address)"
  }
}
