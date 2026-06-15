import Foundation
import Testing

@testable import Moolah

/// Behavioural tests for `CryptoTokenDiscoveryService`. The in-flight
/// coalescer / stress assertions live in `CryptoTokenDiscoveryCoalescerTests`.
@Suite("CryptoTokenDiscoveryService — Resolution")
struct CryptoTokenDiscoveryServiceTests {
  // Reusable USDC-like contract for the ERC-20 paths.
  static let usdcAddress = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
  static let usdcId = "1:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"

  // MARK: - Single-resolve happy paths

  @Test("Resolved mapping → .priced registration persisted")
  func resolvedMappingIsPriced() async throws {
    let subject = makeDiscoverySubject()
    subject.resolver.script(
      .init(chainId: 1, contractAddress: Self.usdcAddress.lowercased()),
      .success(coingecko: "usd-coin", cryptocompare: "USDC", binance: "USDCUSDT"))

    let registration = try await subject.service.resolveOrLoad(
      chain: .ethereum,
      contractAddress: Self.usdcAddress,
      symbol: "USDC",
      name: "USD Coin",
      decimals: 6)

    #expect(registration.pricingStatus == .priced)
    #expect(registration.mapping.coingeckoId == "usd-coin")
    #expect(registration.instrument.id == Self.usdcId)

    let stored = try await subject.registry.cryptoRegistration(byId: Self.usdcId)
    #expect(stored?.pricingStatus == .priced)
    #expect(stored?.mapping.coingeckoId == "usd-coin")
  }

  @Test("performResolution persists the final state in a single registry write (#895)")
  func performResolutionSingleWrite() async throws {
    let subject = makeDiscoverySubject()
    // Scripting the resolver to fail yields `.unpriced`, which differs
    // from the upsert's would-be default (`.priced`) — the exact
    // condition that drove the old `registerCrypto` + `update`
    // double-write.
    struct ProviderFailed: Error {}
    subject.resolver.script(
      .init(chainId: 1, contractAddress: Self.usdcAddress.lowercased()),
      .failure(ProviderFailed()))

    let registration = try await subject.service.resolveOrLoad(
      chain: .ethereum,
      contractAddress: Self.usdcAddress,
      symbol: "USDC",
      name: "USD Coin",
      decimals: 6)

    #expect(registration.pricingStatus == .unpriced)
    let snapshot = subject.registry.snapshot()
    // Exactly one registry write, carrying the final status — never a
    // follow-up `update(_:)`.
    #expect(snapshot.registeredCryptos.count == 1)
    #expect(snapshot.registeredCryptos.first?.pricingStatus == .unpriced)
    #expect(snapshot.updateCallCount == 0)
  }

  @Test("No mapping + not spam → .unpriced")
  func noMappingIsUnpriced() async throws {
    struct ProviderFailed: Error {}
    let subject = makeDiscoverySubject()
    subject.resolver.script(
      .init(chainId: 1, contractAddress: Self.usdcAddress.lowercased()),
      .failure(ProviderFailed()))

    let registration = try await subject.service.resolveOrLoad(
      chain: .ethereum,
      contractAddress: Self.usdcAddress,
      symbol: "OBS",
      name: "Obscure",
      decimals: 18)

    #expect(registration.pricingStatus == .unpriced)
    #expect(registration.mapping.coingeckoId == nil)
    let all = try await subject.registry.allCryptoRegistrations()
    #expect(all.contains { $0.id == Self.usdcId && $0.pricingStatus == .unpriced })
  }

  @Test("Provider success but no mapping ids → .unpriced")
  func providerSucceedsWithoutMappingIsUnpriced() async throws {
    let subject = makeDiscoverySubject()
    subject.resolver.script(
      .init(chainId: 1, contractAddress: Self.usdcAddress.lowercased()),
      .success(coingecko: nil, cryptocompare: nil, binance: nil))

    let registration = try await subject.service.resolveOrLoad(
      chain: .ethereum,
      contractAddress: Self.usdcAddress,
      symbol: "OBS",
      name: "Obscure",
      decimals: 18)

    #expect(registration.pricingStatus == .unpriced)
    #expect(registration.mapping.coingeckoId == nil)
    #expect(registration.mapping.cryptocompareSymbol == nil)
    #expect(registration.mapping.binanceSymbol == nil)
  }

  @Test("Existing registration short-circuits — no resolver call")
  func existingRegistrationShortCircuits() async throws {
    let preexisting = CryptoRegistration(
      instrument: Instrument.crypto(
        chainId: 1, contractAddress: Self.usdcAddress, symbol: "USDC",
        name: "USD Coin", decimals: 6),
      mapping: CryptoProviderMapping(
        instrumentId: Self.usdcId,
        coingeckoId: "usd-coin", cryptocompareSymbol: "USDC", binanceSymbol: "USDCUSDT"),
      pricingStatus: .priced)
    let subject = makeDiscoverySubject(seededRegistrations: [preexisting])

    let registration = try await subject.service.resolveOrLoad(
      chain: .ethereum,
      contractAddress: Self.usdcAddress,
      symbol: "USDC",
      name: "USD Coin",
      decimals: 6)

    #expect(registration.id == preexisting.id)
    #expect(
      subject.resolver.callCount(
        for: .init(chainId: 1, contractAddress: Self.usdcAddress.lowercased())) == 0)
  }

  // MARK: - Local spam heuristics (#1102)

  @Test("Unpriced token with a URL in its name → .spam via local heuristic")
  func unpricedWithDomainNameIsSpam() async throws {
    struct ProviderFailed: Error {}
    let subject = makeDiscoverySubject()
    subject.resolver.script(
      .init(chainId: 1, contractAddress: Self.usdcAddress.lowercased()),
      .failure(ProviderFailed()))

    let registration = try await subject.service.resolveOrLoad(
      chain: .ethereum,
      contractAddress: Self.usdcAddress,
      // Keyword-free symbol so this exercises the domain path, not the
      // keyword path (the name carries both signals).
      symbol: "SCM",
      name: "Visit op-rewards.xyz for details",
      decimals: 18)

    #expect(registration.pricingStatus == .spam)
    #expect(!registration.mapping.hasProviderMapping)
    let stored = try await subject.registry.cryptoRegistration(byId: Self.usdcId)
    #expect(stored?.pricingStatus == .spam)
  }

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

  // MARK: - Canonical-registry impersonation (#1102)

  @Test("Impersonating token is .spam even when a provider returns a price")
  func impersonatingTokenIsSpamEvenWhenPriced() async throws {
    // A non-canonical address claiming the "OP" symbol on Optimism (chain
    // 10). Even with a successful provider price, the canonical-registry
    // impersonation check wins and flags it `.spam`.
    let fakeAddress = "0xdeadbeef00000000000000000000000000000001"
    let subject = makeDiscoverySubject()
    subject.resolver.script(
      .init(chainId: 10, contractAddress: fakeAddress),
      .success(coingecko: "optimism", cryptocompare: nil, binance: nil))

    let registration = try await subject.service.resolveOrLoad(
      chain: .optimism,
      contractAddress: fakeAddress,
      symbol: "OP",
      name: "Optimism",
      decimals: 18)

    #expect(registration.pricingStatus == .spam)
    #expect(!registration.mapping.hasProviderMapping)
    // Impersonation is a synchronous lookup that short-circuits ahead of the
    // provider round-trip — a known impersonator never hits the resolver.
    #expect(
      subject.resolver.callCount(for: .init(chainId: 10, contractAddress: fakeAddress)) == 0)
    let stored = try await subject.registry.cryptoRegistration(
      byId: registration.instrument.id)
    #expect(stored?.pricingStatus == .spam)
  }

  @Test("Impersonating token is .spam even when the resolver finds no price")
  func impersonatingTokenIsSpamWithoutPrice() async throws {
    struct ResolveFailed: Error {}
    let fakeAddress = "0xdeadbeef00000000000000000000000000000002"
    let subject = makeDiscoverySubject()
    subject.resolver.script(
      .init(chainId: 10, contractAddress: fakeAddress), .failure(ResolveFailed()))

    let registration = try await subject.service.resolveOrLoad(
      chain: .optimism,
      contractAddress: fakeAddress,
      symbol: "OP",
      name: "Optimism",
      decimals: 18)

    #expect(registration.pricingStatus == .spam)
    #expect(!registration.mapping.hasProviderMapping)
  }

  @Test("Canonical OP address is not impersonation → stays .priced")
  func canonicalTokenIsNotImpersonation() async throws {
    // OP at its canonical address on Optimism — the registry recognises it
    // as legitimate, so a provider price stands.
    let canonicalAddress = "0x4200000000000000000000000000000000000042"
    let subject = makeDiscoverySubject()
    subject.resolver.script(
      .init(chainId: 10, contractAddress: canonicalAddress),
      .success(coingecko: "optimism", cryptocompare: nil, binance: nil))

    let registration = try await subject.service.resolveOrLoad(
      chain: .optimism,
      contractAddress: canonicalAddress,
      symbol: "OP",
      name: "Optimism",
      decimals: 18)

    #expect(registration.pricingStatus == .priced)
    #expect(registration.mapping.coingeckoId == "optimism")
  }

  @Test("A priced token keeps .priced even when its name contains a domain")
  func pricedDomainBrandedTokenStaysPriced() async throws {
    // yearn.finance / YFI: a legitimately listed token whose name is a
    // domain. Because the provider resolves it, the local domain heuristic
    // must not demote it to .spam.
    let subject = makeDiscoverySubject()
    subject.resolver.script(
      .init(chainId: 1, contractAddress: Self.usdcAddress.lowercased()),
      .success(coingecko: "yearn-finance", cryptocompare: nil, binance: nil))

    let registration = try await subject.service.resolveOrLoad(
      chain: .ethereum,
      contractAddress: Self.usdcAddress,
      symbol: "YFI",
      name: "yearn.finance",
      decimals: 18)

    #expect(registration.pricingStatus == .priced)
    #expect(registration.mapping.coingeckoId == "yearn-finance")
  }

  // MARK: - Chain-id entry point

  @Test("resolveOrLoad(chainId:) for a chain without a ChainConfig registers")
  func resolveByChainIdWithoutChainConfigRegisters() async throws {
    let subject = makeDiscoverySubject()
    subject.resolver.setDefault(.success(coingecko: "usd-coin", cryptocompare: nil, binance: nil))

    // Arbitrum (chain 42161) has no ChainConfig.
    let registration = try await subject.service.resolveOrLoad(
      chainId: 42161,
      contractAddress: "0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8",
      symbol: "USDC",
      name: "USDC",
      decimals: 6)

    #expect(registration.instrument.id == "42161:0xff970a61a04b1ca14834a43f5de4533ebddb5cc8")
    #expect(registration.instrument.decimals == 6)
    #expect(registration.pricingStatus == .priced)
    let snap = subject.registry.snapshot()
    #expect(snap.registeredCryptos.contains { $0.id == registration.instrument.id })
  }

  // MARK: - Re-resolution

  @Test("reResolve(.unpriced → .priced) flips status when provider now succeeds")
  func reResolveUnpricedToPriced() async throws {
    let unpriced = CryptoRegistration(
      instrument: Instrument.crypto(
        chainId: 1, contractAddress: Self.usdcAddress, symbol: "OBS",
        name: "Obscure", decimals: 18),
      mapping: CryptoProviderMapping(
        instrumentId: Self.usdcId,
        coingeckoId: nil, cryptocompareSymbol: nil, binanceSymbol: nil),
      pricingStatus: .unpriced)
    let subject = makeDiscoverySubject(seededRegistrations: [unpriced])
    subject.resolver.script(
      .init(chainId: 1, contractAddress: Self.usdcAddress.lowercased()),
      .success(coingecko: "newly-listed", cryptocompare: nil, binance: nil))

    let updated = try await subject.service.reResolve(unpriced, chain: .ethereum)

    #expect(updated.pricingStatus == .priced)
    #expect(updated.mapping.coingeckoId == "newly-listed")
    let stored = try await subject.registry.cryptoRegistration(byId: Self.usdcId)
    #expect(stored?.pricingStatus == .priced)
    #expect(stored?.mapping.coingeckoId == "newly-listed")
  }

  @Test("reResolve respects registry-current status when caller's snapshot is stale")
  func reResolveSkipsWhenRegistryNoLongerUnpriced() async throws {
    // Caller hands in an `.unpriced` snapshot, but the registry has
    // since been updated to `.spam` (e.g. user classified the token on
    // another device while this device was idle between daily cycles).
    // The "user intent wins" property requires reResolve to re-read the
    // registry and bail out without re-resolving.
    let staleSnapshot = CryptoRegistration(
      instrument: Instrument.crypto(
        chainId: 1, contractAddress: Self.usdcAddress, symbol: "OBS",
        name: "Obscure", decimals: 18),
      mapping: CryptoProviderMapping(
        instrumentId: Self.usdcId,
        coingeckoId: nil, cryptocompareSymbol: nil, binanceSymbol: nil),
      pricingStatus: .unpriced)
    let liveRow = CryptoRegistration(
      instrument: staleSnapshot.instrument,
      mapping: staleSnapshot.mapping,
      pricingStatus: .spam)
    let subject = makeDiscoverySubject(seededRegistrations: [liveRow])
    // Even if the provider would succeed, reResolve must not call it.
    subject.resolver.script(
      .init(chainId: 1, contractAddress: Self.usdcAddress.lowercased()),
      .success(coingecko: "should-not-be-used", cryptocompare: nil, binance: nil))

    let result = try await subject.service.reResolve(staleSnapshot, chain: .ethereum)

    #expect(result.pricingStatus == .spam)
    let resolverKey = CountingRegistrationResolver.Key(
      chainId: 1, contractAddress: Self.usdcAddress.lowercased())
    #expect(subject.resolver.callCount(for: resolverKey) == 0)
  }
}
