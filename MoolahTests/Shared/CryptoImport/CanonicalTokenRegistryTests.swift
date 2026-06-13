import Testing

@testable import Moolah

/// Tests for the bundled canonical token registry used by impersonation
/// detection (issue #1102). The registry pins a curated set of high-value
/// symbols to their legitimate `(chain, address)` deployments; a token using a
/// protected symbol at a non-canonical address is an impersonator.
@Suite("CanonicalTokenRegistry")
struct CanonicalTokenRegistryTests {
  // Well-known canonical addresses (lowercased).
  static let opOptimism = "0x4200000000000000000000000000000000000042"
  static let usdcEthereum = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
  static let usdcOptimism = "0x0b2c639c533813f4aa9d7837caf62653d097ff85"
  static let usdcEOptimism = "0x7f5c764cbc14f9669b88837ca1490cca17c31607"

  // MARK: - Canonical addresses are not impersonation

  @Test("Canonical OP on Optimism is not impersonation")
  func canonicalOpIsLegit() {
    #expect(
      !CanonicalTokenRegistry.isImpersonation(
        chainId: 10, contractAddress: Self.opOptimism, symbol: "OP"))
  }

  @Test("Canonical USDC (native) and bridged USDC.e on Optimism are both legit")
  func bothLegitUsdcDeploymentsPass() {
    #expect(
      !CanonicalTokenRegistry.isImpersonation(
        chainId: 10, contractAddress: Self.usdcOptimism, symbol: "USDC"))
    #expect(
      !CanonicalTokenRegistry.isImpersonation(
        chainId: 10, contractAddress: Self.usdcEOptimism, symbol: "USDC.e"))
  }

  @Test("Case-insensitive symbol and checksummed address still match")
  func caseInsensitiveMatch() {
    #expect(
      !CanonicalTokenRegistry.isImpersonation(
        chainId: 10, contractAddress: Self.opOptimism.uppercased(), symbol: "op"))
  }

  @Test("Canonical USDC on Ethereum is not impersonation")
  func canonicalUsdcMainnetIsLegit() {
    #expect(
      !CanonicalTokenRegistry.isImpersonation(
        chainId: 1, contractAddress: Self.usdcEthereum, symbol: "USDC"))
  }

  // MARK: - Impersonators are flagged

  @Test("A different address with a protected symbol is impersonation")
  func fakeOpIsImpersonation() {
    #expect(
      CanonicalTokenRegistry.isImpersonation(
        chainId: 10,
        contractAddress: "0xdeadbeef00000000000000000000000000000001",
        symbol: "OP"))
  }

  @Test("A fake USDC on Ethereum is impersonation")
  func fakeUsdcIsImpersonation() {
    #expect(
      CanonicalTokenRegistry.isImpersonation(
        chainId: 1,
        contractAddress: "0x0000000000000000000000000000000000000bad",
        symbol: "USDC"))
  }

  // MARK: - Out-of-scope cases never flag

  @Test("A symbol not protected on the chain is never impersonation")
  func opOnEthereumIsNotProtected() {
    // OP is an Optimism token; there is no canonical OP on Ethereum, so any
    // "OP" on chain 1 is out of scope for this registry (not flagged here).
    #expect(
      !CanonicalTokenRegistry.isImpersonation(
        chainId: 1,
        contractAddress: "0x0000000000000000000000000000000000000042",
        symbol: "OP"))
  }

  @Test("An unprotected symbol is never impersonation")
  func unprotectedSymbolIsNeverImpersonation() {
    #expect(
      !CanonicalTokenRegistry.isImpersonation(
        chainId: 1,
        contractAddress: "0x0000000000000000000000000000000000000001",
        symbol: "OBSCURETOKEN"))
  }

  @Test("Native tokens (nil address) are never impersonation")
  func nativeTokenIsNeverImpersonation() {
    #expect(
      !CanonicalTokenRegistry.isImpersonation(
        chainId: 10, contractAddress: nil, symbol: "OP"))
  }

  @Test("Bundled data covers all four supported chains with non-empty sets")
  func bundledDataIsWellFormed() {
    for chainId in [1, 10, 8453, 137] {
      let entries = CanonicalTokenRegistry.bundled[chainId]
      #expect(entries != nil, "missing chain \(chainId)")
      #expect(entries?.isEmpty == false)
      // Every protected symbol must carry at least one address, all lowercased.
      for (symbol, addresses) in entries ?? [:] {
        #expect(!addresses.isEmpty, "\(symbol) on \(chainId) has no addresses")
        #expect(symbol == symbol.uppercased(), "\(symbol) key must be uppercased")
        for address in addresses {
          #expect(address == address.lowercased(), "\(address) must be lowercased")
          #expect(address.hasPrefix("0x"))
        }
      }
    }
  }
}
