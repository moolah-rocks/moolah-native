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

// MARK: - Shared test helper

/// Builds a `CryptoRegistration` whose `instrument.id` matches `id` exactly.
/// Extracts the contract address from the `id` suffix (everything after `:`)
/// unless the suffix is `"native"`, in which case `contractAddress` is nil.
private func reg(
  _ id: String, chainId: Int, coingeckoId: String?
) -> CryptoRegistration {
  let address: String? =
    id.hasSuffix(":native")
    ? nil : String(id.split(separator: ":", maxSplits: 1)[1])
  return CryptoRegistration(
    instrument: .crypto(
      chainId: chainId, contractAddress: address, symbol: "X", name: "X", decimals: 18),
    mapping: CryptoProviderMapping(
      instrumentId: id, coingeckoId: coingeckoId,
      cryptocompareSymbol: nil, binanceSymbol: nil))
}

// MARK: - Dynamic derivation tests

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
}

// MARK: - Observe on registry-change tests

@Suite("CanonicalInstrumentResolver — observe on registry change")
struct CanonicalInstrumentResolverObserveTests {
  @Test("a registry-change tick triggers a re-derive")
  func tickRefreshesMap() async throws {
    let resolver = CanonicalInstrumentResolver()
    let registry = StubInstrumentRegistry(cryptoRegistrations: [
      reg("1:0xccc", chainId: 1, coingeckoId: "discovered-token"),
      reg("10:0xddd", chainId: 10, coingeckoId: "discovered-token"),
    ])
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    let task = resolver.startObserving(registry: registry, changes: stream)

    // Poll until the initial refresh lands (no snap-read of async state).
    try await pollUntil { resolver.isAlias("10:0xddd") }
    #expect(resolver.canonicalId(for: "10:0xddd") == "1:0xccc")

    task.cancel()
    continuation.finish()
  }
}

// MARK: - pollUntil helper

/// Polls `condition` in a tight loop until it returns `true` or `timeout`
/// elapses. Throws `PollTimeout` on expiry. Matches the 10-second wait
/// convention (guides/AI_ASSISTANT_GUIDE.md — test wait timeouts).
private func pollUntil(
  timeout: Duration = .seconds(10),
  _ condition: () -> Bool
) async throws {
  let deadline = ContinuousClock().now.advanced(by: timeout)
  while !condition() {
    if ContinuousClock().now >= deadline {
      throw PollTimeout()
    }
    try await Task.sleep(for: .milliseconds(10))
    if Task.isCancelled { return }
  }
}

private struct PollTimeout: Error, CustomStringConvertible {
  var description: String { "pollUntil timed out waiting for condition" }
}
