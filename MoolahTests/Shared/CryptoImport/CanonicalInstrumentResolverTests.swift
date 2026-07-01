// MoolahTests/Shared/CryptoImport/CanonicalInstrumentResolverTests.swift

import Foundation
import Testing

@testable import Moolah

@Suite("CanonicalInstrumentResolver — static base layer")
struct CanonicalInstrumentResolverTests {
  @Test("ETH L2 natives resolve to mainnet native before any alias exists")
  func ethL2NativesCollapse() {
    let resolver = CanonicalInstrumentResolver()  // empty dynamic map
    #expect(resolver.canonicalId(for: "10:native") == "1:native")
    #expect(resolver.canonicalId(for: "8453:native") == "1:native")
    #expect(resolver.isAlias("10:native"))
    #expect(resolver.isAlias("8453:native"))
  }

  @Test("mainnet native is its own canonical")
  func mainnetNativeUnchanged() {
    let resolver = CanonicalInstrumentResolver()
    #expect(resolver.canonicalId(for: "1:native") == "1:native")
    #expect(!resolver.isAlias("1:native"))
  }

  @Test("L2 USDC/USDT collapse to their mainnet contracts")
  func l2StablecoinsCollapse() {
    let resolver = CanonicalInstrumentResolver()
    #expect(
      resolver.canonicalId(for: "10:0x0b2c639c533813f4aa9d7837caf62653d097ff85")
        == "1:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")  // OP USDC → mainnet USDC
    #expect(
      resolver.canonicalId(for: "137:0xc2132d05d31c914a87c6611c10748aeb04b58e8f")
        == "1:0xdac17f958d2ee523a2206206994597c13d831ec7")  // Polygon USDT → mainnet USDT
  }

  @Test("an unknown id is its own canonical")
  func unknownIdUnchanged() {
    let resolver = CanonicalInstrumentResolver()
    #expect(resolver.canonicalId(for: "42:0xdeadbeef") == "42:0xdeadbeef")
    #expect(!resolver.isAlias("42:0xdeadbeef"))
  }

  @Suite("static-map drift guard")
  struct DriftTests {
    /// Every non-native address on the *alias* side of the static base map must
    /// still be a known-legitimate deployment in `CanonicalTokenRegistry`, so a
    /// registry re-vendor that moves an address forces this map to be updated in
    /// lock-step rather than silently collapsing the wrong token.
    @Test("each static L2 stablecoin alias is a recognised deployment")
    func staticAliasesAreRecognised() throws {
      for aliasId in CanonicalInstrumentResolver.staticBaseMap.keys {
        let parts = aliasId.split(separator: ":", maxSplits: 1)
        let chainId = try #require(Int(parts[0]))
        let address = String(parts[1])
        guard address != "native" else { continue }
        #expect(
          CanonicalTokenRegistry.symbol(chainId: chainId, contractAddress: address) != nil,
          "static alias \(aliasId) no longer recognised by CanonicalTokenRegistry")
      }
    }
  }
}
