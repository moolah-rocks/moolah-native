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
}
