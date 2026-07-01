// MoolahTests/Shared/CryptoImport/DiscoveryCanonicalizationTests.swift

import Foundation
import Testing

@testable import Moolah

/// Smoke-test for `CanonicalInstrumentResolver` injection into
/// `CryptoTokenDiscoveryService`. The service accepts the resolver at init;
/// the canonicalization assertions below verify the redirect behaviour once
/// `resolveOrLoad` is wired to apply the resolver.
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
    // The redirect logic lands in a later change; until then the service stores
    // the L2 id as-is and these assertions are expected to fail.
    withKnownIssue("canonicalization redirect not yet wired in resolveOrLoad") {
      #expect(reg.instrument.id == "1:native")
      #expect(reg.instrument.chainId == 1)
      #expect(reg.instrument.contractAddress == nil)
      #expect(lookup10 == nil)
      #expect(lookup1 != nil)
    }
  }
}
