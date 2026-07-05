// MoolahTests/Shared/InstrumentPickerCanonicalizationTests.swift

import Foundation
import Testing

@testable import Moolah

/// The manual picker must not mint a retired L2 id: adding an L2-stablecoin
/// catalog hit must persist under the canonical mainnet id.
@Suite("InstrumentPickerStore — canonical registration")
@MainActor
struct InstrumentPickerCanonicalizationTests {

  @Test("adding Optimism USDC registers under the canonical mainnet id, not the L2 id")
  func addingOptimismUSDCRegistersUnderMainnetId() async throws {
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let resolver = CanonicalInstrumentResolver()
    let store = InstrumentPickerStore(
      registry: registry,
      resolutionClient: ConfigurableTokenResolutionClient(
        coingeckoId: "usd-coin", binanceSymbol: nil),
      canonicalResolver: resolver,
      kinds: [.cryptoToken])

    let opUSDC = Instrument.crypto(
      chainId: 10,
      contractAddress: "0x0b2c639c533813f4aa9d7837caf62653d097ff85",
      symbol: "USDC",
      name: "USD Coin",
      decimals: 18)

    let added = try #require(await store.registerForTesting(opUSDC))
    #expect(added.id == "1:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")

    let registration = try await registry.cryptoRegistration(byId: added.id)
    #expect(registration != nil)
    // No retired-id row was minted.
    let retiredRegistration = try await registry.cryptoRegistration(byId: opUSDC.id)
    #expect(retiredRegistration == nil)
  }

  @Test("adding an already-canonical mainnet token is unchanged (no double canonicalize)")
  func addingMainnetTokenIsUnchanged() async throws {
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let resolver = CanonicalInstrumentResolver()
    let store = InstrumentPickerStore(
      registry: registry,
      resolutionClient: ConfigurableTokenResolutionClient(
        coingeckoId: "uniswap", binanceSymbol: nil),
      canonicalResolver: resolver,
      kinds: [.cryptoToken])

    let uniMainnet = Instrument.crypto(
      chainId: 1,
      contractAddress: "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984",
      symbol: "UNI",
      name: "Uniswap",
      decimals: 18)

    let added = try #require(await store.registerForTesting(uniMainnet))
    #expect(added.id == uniMainnet.id)

    let registration = try await registry.cryptoRegistration(byId: uniMainnet.id)
    #expect(registration != nil)
  }

  @Test(
    "adding an already-registered canonical instrument returns the existing row, skips re-resolve")
  func addingAlreadyRegisteredCanonicalReturnsExisting() async throws {
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    // Pre-seed the canonical USDC row directly in the registry.
    let mainnetUSDC = Instrument.crypto(
      chainId: 1,
      contractAddress: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      symbol: "USDC",
      name: "USD Coin",
      decimals: 6)
    let mapping = CryptoProviderMapping(
      instrumentId: mainnetUSDC.id,
      coingeckoId: "usd-coin",
      binanceSymbol: nil)
    try await registry.registerCrypto(mainnetUSDC, mapping: mapping)

    // Resolution client that tracks calls — it must NOT be called when the
    // canonical row already exists.
    let client = CountingTokenResolutionClient()
    let resolver = CanonicalInstrumentResolver()
    let store = InstrumentPickerStore(
      registry: registry,
      resolutionClient: client,
      canonicalResolver: resolver,
      kinds: [.cryptoToken])

    let opUSDC = Instrument.crypto(
      chainId: 10,
      contractAddress: "0x0b2c639c533813f4aa9d7837caf62653d097ff85",
      symbol: "USDC",
      name: "USD Coin",
      decimals: 18)

    let added = try #require(await store.registerForTesting(opUSDC))
    #expect(added.id == mainnetUSDC.id)
    // The existing canonical registration was returned — no network call.
    #expect(client.callCount == 0)
  }

  @Test("nil resolver (preview / test without wiring) falls through unchanged")
  func nilResolverPassesThrough() async throws {
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let store = InstrumentPickerStore(
      registry: registry,
      resolutionClient: ConfigurableTokenResolutionClient(
        coingeckoId: "op-usdc", binanceSymbol: nil),
      canonicalResolver: nil,  // no resolver wired
      kinds: [.cryptoToken])

    let opUSDC = Instrument.crypto(
      chainId: 10,
      contractAddress: "0x0b2c639c533813f4aa9d7837caf62653d097ff85",
      symbol: "USDC",
      name: "USD Coin",
      decimals: 18)

    let added = try #require(await store.registerForTesting(opUSDC))
    // Falls through unchanged — no canonicalization.
    #expect(added.id == opUSDC.id)
  }
}

// MARK: - Test doubles

/// Returns a fixed set of provider ids on every `resolve` call.
private struct ConfigurableTokenResolutionClient: TokenResolutionClient {
  let coingeckoId: String?
  let binanceSymbol: String?

  func resolve(
    chainId: Int, contractAddress: String?, symbol: String?, isNative: Bool
  ) async throws -> TokenResolutionResult {
    TokenResolutionResult(
      coingeckoId: coingeckoId,
      binanceSymbol: binanceSymbol,
      resolvedName: nil,
      resolvedSymbol: nil,
      resolvedDecimals: nil)
  }
}

/// Counts `resolve` calls so tests can assert "no network call was made".
private final class CountingTokenResolutionClient: TokenResolutionClient, @unchecked Sendable {
  private(set) var callCount: Int = 0

  func resolve(
    chainId: Int, contractAddress: String?, symbol: String?, isNative: Bool
  ) async throws -> TokenResolutionResult {
    callCount += 1
    return TokenResolutionResult(
      coingeckoId: "usd-coin",
      binanceSymbol: nil,
      resolvedName: nil,
      resolvedSymbol: nil,
      resolvedDecimals: nil)
  }
}
