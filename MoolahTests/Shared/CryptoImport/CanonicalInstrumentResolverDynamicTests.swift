// MoolahTests/Shared/CryptoImport/CanonicalInstrumentResolverDynamicTests.swift

import Foundation
import Testing

@testable import Moolah

@Suite("CanonicalInstrumentResolver — dynamic derivation")
struct CanonicalInstrumentResolverDynamicTests {
  @Test("L2 members of a shared assetKey alias the mainnet member")
  func mainnetWinsWithinGroup() {
    let map = CanonicalInstrumentResolver.derive(from: [
      reg("1:native", chainId: 1, coingeckoId: "ethereum"),
      reg("10:native", chainId: 10, coingeckoId: "ethereum"),
      reg("8453:native", chainId: 8453, coingeckoId: "ethereum"),
    ])
    #expect(map["10:native"] == "1:native")
    #expect(map["8453:native"] == "1:native")
    #expect(map["1:native"] == nil)  // canonical is never an alias of itself
  }

  @Test("no mainnet member → lowest chainId is canonical")
  func lowestChainIdWinsWhenNoMainnet() {
    let map = CanonicalInstrumentResolver.derive(from: [
      reg("10:0xaaa", chainId: 10, coingeckoId: "some-l2-token"),
      reg("8453:0xbbb", chainId: 8453, coingeckoId: "some-l2-token"),
    ])
    #expect(map["8453:0xbbb"] == "10:0xaaa")
    #expect(map["10:0xaaa"] == nil)
  }

  @Test("two chain-10 members at the same non-1 chainId — lex-smallest id is canonical")
  func tiebreakLexSmallestId() {
    // Both tokens share chainId 10 and the same assetKey (coingeckoId).
    // No mainnet member and no lower chainId — tiebreak falls to the
    // lexicographically-smallest instrument id. "10:0xaaa" < "10:0xbbb",
    // so 0xaaa is canonical and 0xbbb maps to it.
    let map = CanonicalInstrumentResolver.derive(from: [
      reg("10:0xbbb", chainId: 10, coingeckoId: "same-asset"),
      reg("10:0xaaa", chainId: 10, coingeckoId: "same-asset"),
    ])
    #expect(map["10:0xbbb"] == "10:0xaaa")
    #expect(map["10:0xaaa"] == nil)  // canonical is not an alias of itself
  }

  @Test("a no-key instrument is its own canonical (never aliased)")
  func noKeyInstrumentUnchanged() {
    // Two no-key tokens share no assetKey (each falls back to its own id).
    let map = CanonicalInstrumentResolver.derive(from: [
      reg("10:0xaaa", chainId: 10, coingeckoId: nil),
      reg("8453:0xbbb", chainId: 8453, coingeckoId: nil),
    ])
    #expect(map.isEmpty)
  }

  @Test("refresh publishes the derived dynamic map to lookups")
  func refreshPublishesDynamicMap() {
    let resolver = CanonicalInstrumentResolver()
    // A discovered ERC-20 pair NOT in the static base layer.
    resolver.refresh(with: [
      reg("1:0xccc", chainId: 1, coingeckoId: "discovered-token"),
      reg("10:0xddd", chainId: 10, coingeckoId: "discovered-token"),
    ])
    #expect(resolver.canonicalId(for: "10:0xddd") == "1:0xccc")
    #expect(resolver.isAlias("10:0xddd"))
  }

  // MARK: - Layer-composition tests

  /// Regression: `derive` picks the lowest-chainId member as canonical when
  /// there is no mainnet member. If that member is itself a static-alias key
  /// (e.g. Optimism USDC, chainId 10), the dynamic map used to store the
  /// static-alias as the canonical id. `canonicalId(for:)` would then return
  /// a RETIRED id rather than the true mainnet id.
  ///
  /// After the fix, `derive` resolves the selected canonical through
  /// `staticBaseMap` before writing the map, and `canonicalId(for:)` also
  /// re-resolves the dynamic result through the static layer — so both layers
  /// compose and the invariant holds.
  @Test(
    "dynamic + static layers compose: no-mainnet group with static-alias member resolves to mainnet canonical"
  )
  func dynamicStaticLayersCompose() {
    // Arbitrum USDC (chainId 42161) — not in staticBaseMap.
    let arbitrumUSDC = "42161:0xaf88d065e77c8cc2239327c5edb3a432268e5831"
    // Optimism USDC (chainId 10) — IS a static-alias of mainnet USDC.
    let optimismUSDC = "10:0x0b2c639c533813f4aa9d7837caf62653d097ff85"
    let mainnnetUSDC = "1:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"

    let resolver = CanonicalInstrumentResolver()
    // No mainnet member. `derive` selects Optimism (lowest chainId = 10) as
    // the group canonical, but Optimism USDC is itself a static-alias key.
    resolver.refresh(with: [
      reg(arbitrumUSDC, chainId: 42161, coingeckoId: "usd-coin"),
      reg(optimismUSDC, chainId: 10, coingeckoId: "usd-coin"),
    ])

    // The Arbitrum USDC must resolve all the way to the mainnet canonical,
    // not to the intermediate Optimism USDC (the retired static-alias key).
    #expect(resolver.canonicalId(for: arbitrumUSDC) == mainnnetUSDC)
    #expect(resolver.isAlias(arbitrumUSDC))

    // Optimism USDC still resolves correctly via the static layer.
    #expect(resolver.canonicalId(for: optimismUSDC) == mainnnetUSDC)
    #expect(resolver.isAlias(optimismUSDC))
  }

  @Test("refresh(from:) swallows registry errors and leaves map unchanged")
  func refreshErrorDoesNotCorruptMap() async {
    let resolver = CanonicalInstrumentResolver()
    // Seed a known alias pair via the synchronous seam.
    resolver.refresh(with: [
      reg("1:0xccc", chainId: 1, coingeckoId: "seed-token"),
      reg("10:0xddd", chainId: 10, coingeckoId: "seed-token"),
    ])
    #expect(resolver.canonicalId(for: "10:0xddd") == "1:0xccc")

    // A registry that always throws must not corrupt the existing map.
    await resolver.refresh(from: ThrowingCryptoRegistryStub())

    // Dynamic map must be unchanged after the error.
    #expect(resolver.canonicalId(for: "10:0xddd") == "1:0xccc")
    #expect(resolver.isAlias("10:0xddd"))
  }
}
