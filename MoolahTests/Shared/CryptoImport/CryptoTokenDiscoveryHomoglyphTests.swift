import Foundation
import Testing

@testable import Moolah

/// End-to-end coverage for the mixed-script (homoglyph) spam path through
/// `CryptoTokenDiscoveryService.resolveOrLoad`. Kept in its own `@Suite` so
/// `CryptoTokenDiscoveryServiceTests` stays under the `type_body_length` limit.
@Suite("CryptoTokenDiscoveryService homoglyph spam")
struct CryptoTokenDiscoveryHomoglyphTests {
  @Test("Unpriced token with a mixed-script (homoglyph) symbol → .spam via local heuristic")
  func unpricedWithHomoglyphSymbolIsSpam() async throws {
    struct ProviderFailed: Error {}
    // A non-canonical address claiming "USD" + Cyrillic Es (U+0421). It
    // renders as "USDC" but is not byte-equal, so the exact-match
    // impersonation check misses it; the mixed-script heuristic catches it.
    let fakeAddress = "0xdeadbeef00000000000000000000000000000003"
    let subject = makeDiscoverySubject()
    subject.resolver.script(
      .init(chainId: 1, contractAddress: fakeAddress),
      .failure(ProviderFailed()))

    let registration = try await subject.service.resolveOrLoad(
      chain: .ethereum,
      contractAddress: fakeAddress,
      symbol: "USD\u{0421}",
      name: "USD\u{0421}",
      decimals: 18)

    #expect(registration.pricingStatus == .spam)
    #expect(!registration.mapping.hasProviderMapping)
    let stored = try await subject.registry.cryptoRegistration(
      byId: registration.instrument.id)
    #expect(stored?.pricingStatus == .spam)
  }
}
