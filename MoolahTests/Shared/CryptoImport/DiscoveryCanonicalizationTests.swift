// MoolahTests/Shared/CryptoImport/DiscoveryCanonicalizationTests.swift

import Foundation
import Testing

@testable import Moolah

/// Smoke-tests for `CanonicalInstrumentResolver` injection into
/// `CryptoTokenDiscoveryService`. Verifies that `resolveOrLoad` collapses
/// L2 native tokens and L2 stablecoin deployments onto their canonical
/// mainnet ids, and that unknown tokens are stored unchanged.
@Suite("CryptoTokenDiscovery — canonicalization")
struct DiscoveryCanonicalizationTests {
  @Test("OP native resolves and persists under the canonical mainnet id")
  func opNativeCanonicalizes() async throws {
    let registry = StubInstrumentRegistry()
    let resolver = CountingRegistrationResolver()
    let discovery = CryptoTokenDiscoveryService(
      registry: registry,
      resolver: resolver,
      canonicalResolver: CanonicalInstrumentResolver())
    let reg = try await discovery.resolveOrLoad(
      chainId: 10, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    let lookup10 = try await registry.cryptoRegistration(byId: "10:native")
    let lookup1 = try await registry.cryptoRegistration(byId: "1:native")
    #expect(reg.instrument.id == "1:native")
    #expect(reg.instrument.chainId == 1)
    #expect(reg.instrument.contractAddress == nil)
    #expect(lookup10 == nil)
    #expect(lookup1 != nil)
  }

  @Test("L2 USDC resolves under the mainnet contract with mainnet value fields")
  func opUSDCCanonicalizes() async throws {
    let registry = StubInstrumentRegistry()
    let discovery = CryptoTokenDiscoveryService(
      registry: registry,
      resolver: CountingRegistrationResolver(),
      canonicalResolver: CanonicalInstrumentResolver())
    let reg = try await discovery.resolveOrLoad(
      chainId: 10,
      contractAddress: "0x0b2c639c533813f4aa9d7837caf62653d097ff85",
      symbol: "USDC",
      name: "USD Coin",
      decimals: 6)
    #expect(reg.instrument.id == "1:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")
    #expect(reg.instrument.chainId == 1)
    #expect(reg.instrument.contractAddress == "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")
  }

  @Test("An unknown ERC-20 is stored under its own id")
  func unknownTokenUnchanged() async throws {
    let registry = StubInstrumentRegistry()
    let discovery = CryptoTokenDiscoveryService(
      registry: registry,
      resolver: CountingRegistrationResolver(),
      canonicalResolver: CanonicalInstrumentResolver())
    let reg = try await discovery.resolveOrLoad(
      chainId: 10, contractAddress: "0xdeadbeef", symbol: "ZZZ", name: "Zzz", decimals: 18)
    #expect(reg.instrument.id == "10:0xdeadbeef")
  }
}
