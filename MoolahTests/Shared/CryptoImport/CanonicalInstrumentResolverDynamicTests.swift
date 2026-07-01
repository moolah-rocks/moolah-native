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
