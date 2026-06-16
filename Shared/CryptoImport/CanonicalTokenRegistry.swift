import Foundation

/// Bundled, chain-scoped registry of canonical contract addresses for a
/// curated set of high-value / impersonation-prone token symbols (stablecoins,
/// wrapped assets, blue-chips, governance). Used to detect spam tokens that
/// mimic a popular token by reusing its symbol at a different address —
/// e.g. a fake "OP" anywhere other than Optimism's `0x4200…0042`, or a
/// counterfeit "USDC". See issue #1102.
///
/// The data lives in the generated `CanonicalTokenRegistry+Bundled.swift`,
/// produced from authoritative token lists by
/// `scripts/vendor-token-registry.sh`. Each protected symbol keeps **all** of
/// its legitimate deployments per chain (native + bridged, e.g. USDC and
/// USDC.e), so flagging an impersonator never trips a real token.
enum CanonicalTokenRegistry {
  /// Returns `true` when `symbol` is protected on `chainId` but
  /// `contractAddress` is not one of its known-legitimate deployments — i.e.
  /// the token is impersonating a popular token.
  ///
  /// Returns `false` (not impersonation) when the token is native (`nil`
  /// address), when the symbol is not protected on that chain, or when the
  /// address is a known-legitimate deployment. Symbol matching is
  /// case-insensitive; addresses are compared lowercased.
  static func isImpersonation(
    chainId: Int,
    contractAddress: String?,
    symbol: String
  ) -> Bool {
    guard let contractAddress else { return false }
    let key = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard let canonical = bundled[chainId]?[key] else { return false }
    return !canonical.contains(contractAddress.lowercased())
  }

  /// The canonical (uppercase) symbol for the token deployed at
  /// `contractAddress` on `chainId`, or `nil` when the address is not a
  /// known-legitimate deployment in the bundled registry. Native (`nil`)
  /// addresses return `nil`.
  ///
  /// The bundled symbols are the standard tickers the major price providers
  /// key on, so the result doubles as a CryptoCompare `fsym` for a
  /// recognised token — used to give CoinGecko-only tokens (e.g. USDC, DAI,
  /// which CryptoCompare omits from its contract-address index) a
  /// date-anchored deep-history provider. This is the reverse of
  /// `isImpersonation`: it returns a symbol only for an address the registry
  /// recognises as legitimate, so a look-alike at a non-canonical address
  /// yields `nil`.
  static func symbol(chainId: Int, contractAddress: String?) -> String? {
    guard let contractAddress else { return nil }
    let needle = contractAddress.lowercased()
    guard let symbolsForChain = bundled[chainId] else { return nil }
    for (protectedSymbol, addresses) in symbolsForChain where addresses.contains(needle) {
      return protectedSymbol
    }
    return nil
  }
}
