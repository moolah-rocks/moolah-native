import Foundation
import Testing

@testable import Moolah

// MARK: - Shared helpers

/// Thread-safe string accumulator used to assert that metadata callbacks
/// are (or are not) invoked. Mirrors the lock-bracket pattern used in
/// `CryptoTokenDiscoveryTestDoubles.swift`.
///
/// `@unchecked Sendable`: mutable state guarded by `NSLock`; lock-bracket
/// pattern, the project convention for non-actor concurrent test stubs.
final class CallTracker: @unchecked Sendable {
  private let lock = NSLock()
  private var calls: [String] = []

  func append(_ symbol: String) {
    lock.withLock { calls.append(symbol) }
  }

  var isEmpty: Bool { lock.withLock { calls.isEmpty } }
  var all: [String] { lock.withLock { calls } }
}

// MARK: - Test suite

@Suite("ExchangeSyncEngine resolution")
struct ExchangeSyncEngineResolutionTests {

  private func depositRow(_ symbol: String, _ amount: Decimal)
    -> ExchangeImportedTransaction
  {
    ExchangeImportedTransaction(
      externalId: "ext-\(symbol)",
      occurredAt: Date(timeIntervalSince1970: 1_762_000_000),
      category: "DEPOSIT", direction: .credit, assetSymbol: symbol,
      amount: amount, isFiat: false, orderId: nil)
  }

  private func account() -> Account {
    Account(
      name: "Coinstash", type: .exchange,
      instrument: .AUD, exchangeProvider: .coinstash)
  }

  @Test
  func opDepositResolvesToRealOptimismOPNotSpam() async throws {
    let registry = StubInstrumentRegistry()
    let meta = StubMetadataResolver([
      "OP": ExchangeAssetMetadata(
        symbol: "OP", name: "Optimism",
        chains: [
          ExchangeAssetChain(
            chainId: 10,
            contractAddress: "0x4200000000000000000000000000000000000042",
            decimals: 18)
        ])
    ])
    let result = try await makeExchangeSyncEngine(registry: registry).build(
      account: account(), imported: [depositRow("OP", 40167)], metadata: meta)
    let leg = try #require(result.candidates.first?.transaction.legs.first)
    #expect(leg.instrument.id == "10:0x4200000000000000000000000000000000000042")
    #expect(leg.instrument.decimals == 18)
  }

  @Test
  func btcShortCircuitsWithoutMetadataCall() async throws {
    let registry = StubInstrumentRegistry(
      cryptoRegistrations: CryptoRegistration.builtInPresets)
    let tracker = CallTracker()
    let meta = StubMetadataResolver([:], onCall: { tracker.append($0) })
    let result = try await makeExchangeSyncEngine(registry: registry).build(
      account: account(), imported: [depositRow("BTC", 1)], metadata: meta)
    let leg = try #require(result.candidates.first?.transaction.legs.first)
    #expect(leg.instrument.id == "0:native")
    #expect(leg.instrument.decimals == 8)
    #expect(tracker.isEmpty)
  }

  @Test
  func multiChainPicksEthereumCanonical() async throws {
    let registry = StubInstrumentRegistry()
    let meta = StubMetadataResolver([
      "USDC": ExchangeAssetMetadata(
        symbol: "USDC", name: "USDC",
        chains: [
          ExchangeAssetChain(
            chainId: 10,
            contractAddress: "0x7f5c764cbc14f9669b88837ca1490cca17c31607",
            decimals: 6),
          ExchangeAssetChain(
            chainId: 1,
            contractAddress: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
            decimals: 6),
        ])
    ])
    let result = try await makeExchangeSyncEngine(registry: registry).build(
      account: account(), imported: [depositRow("USDC", 100)], metadata: meta)
    let leg = try #require(result.candidates.first?.transaction.legs.first)
    #expect(leg.instrument.id == "1:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")
  }

  @Test
  func nativeContractNilBuildsNativeInstrument() async throws {
    let registry = StubInstrumentRegistry()
    let meta = StubMetadataResolver([
      "ETH": ExchangeAssetMetadata(
        symbol: "ETH", name: "Ethereum",
        chains: [ExchangeAssetChain(chainId: 1, contractAddress: nil, decimals: 18)])
    ])
    let result = try await makeExchangeSyncEngine(registry: registry).build(
      account: account(), imported: [depositRow("ETH", 2)], metadata: meta)
    let leg = try #require(result.candidates.first?.transaction.legs.first)
    #expect(leg.instrument.id == "1:native")
  }

  @Test
  func noEvmMetadataUsesRegistryFallback() async throws {
    let real = CryptoRegistration(
      instrument: .crypto(
        chainId: 1399, contractAddress: nil, symbol: "SOL",
        name: "Solana", decimals: 9),
      mapping: CryptoProviderMapping(
        instrumentId: "1399:native", coingeckoId: "solana",
        binanceSymbol: nil))
    let registry = StubInstrumentRegistry(
      instruments: [real.instrument], cryptoRegistrations: [real])
    let meta = StubMetadataResolver([
      "SOL": ExchangeAssetMetadata(symbol: "SOL", name: "Solana", chains: [])
    ])
    let result = try await makeExchangeSyncEngine(registry: registry).build(
      account: account(), imported: [depositRow("SOL", 5)], metadata: meta)
    let leg = try #require(result.candidates.first?.transaction.legs.first)
    #expect(leg.instrument.id == "1399:native")
  }

  @Test
  func multiChainNoEthereumPicksOptimismOverBase() async throws {
    // Chain preference: Ethereum (1) first, then Optimism (10), then Base (8453).
    // When Ethereum is absent, Optimism must win over Base.
    let registry = StubInstrumentRegistry()
    let meta = StubMetadataResolver([
      "OP": ExchangeAssetMetadata(
        symbol: "OP", name: "Optimism",
        chains: [
          ExchangeAssetChain(
            chainId: 8453,
            contractAddress: "0x4200000000000000000000000000000000000042",
            decimals: 18),
          ExchangeAssetChain(
            chainId: 10,
            contractAddress: "0x4200000000000000000000000000000000000042",
            decimals: 18),
        ])
    ])
    let result = try await makeExchangeSyncEngine(registry: registry).build(
      account: account(), imported: [depositRow("OP", 5)], metadata: meta)
    let leg = try #require(result.candidates.first?.transaction.legs.first)
    #expect(leg.instrument.id.hasPrefix("10:"))
  }

  @Test
  func transientMetadataErrorThrows() async throws {
    struct Boom: Error {}
    struct Throwing: ExchangeAssetMetadataResolving {
      func assetMetadata(forSymbol symbol: String) async throws
        -> ExchangeAssetMetadata?
      { throw Boom() }
    }
    let registry = StubInstrumentRegistry()
    await #expect(throws: Boom.self) {
      _ = try await makeExchangeSyncEngine(registry: registry).build(
        account: account(), imported: [depositRow("OP", 1)], metadata: Throwing())
    }
  }

  @Test
  func fiatLegSkipsMetadata() async throws {
    let registry = StubInstrumentRegistry()
    let tracker = CallTracker()
    let meta = StubMetadataResolver([:], onCall: { tracker.append($0) })
    let row = ExchangeImportedTransaction(
      externalId: "f1", occurredAt: Date(timeIntervalSince1970: 1_762_000_000),
      category: "DEPOSIT", direction: .credit, assetSymbol: "AUD",
      amount: 50, isFiat: true, orderId: nil)
    let result = try await makeExchangeSyncEngine(registry: registry).build(
      account: account(), imported: [row], metadata: meta)
    let leg = try #require(result.candidates.first?.transaction.legs.first)
    #expect(leg.instrument == .AUD)
    #expect(tracker.isEmpty)
  }
}
