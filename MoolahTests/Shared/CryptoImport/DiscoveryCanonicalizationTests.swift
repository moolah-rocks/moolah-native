// MoolahTests/Shared/CryptoImport/CryptoTokenDiscoveryCanonicalizationTests.swift

import Foundation
import Testing

@testable import Moolah

/// Wiring smoke test for `CanonicalInstrumentResolver` inside
/// `CryptoTokenDiscoveryService`. Task 1 proves the `canonicalResolver:`
/// parameter exists and that the service accepts it; Task 4 will make the
/// canonicalization assertion pass by implementing the redirecting logic.
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
    // Task 4 implements the redirect; until then the service stores the
    // L2 id as-is and the assertions below are expected to fail.
    #expect(reg.instrument.id == "1:native")
    #expect(reg.instrument.chainId == 1)
    #expect(reg.instrument.contractAddress == nil)
    #expect(try await registry.cryptoRegistration(byId: "10:native") == nil)
    #expect(try await registry.cryptoRegistration(byId: "1:native") != nil)
  }
}
