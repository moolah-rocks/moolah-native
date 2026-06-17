import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("InstrumentRegistryRepository — reconcileProviderMappings")
@MainActor
struct InstrumentRegistryReconcileTests {
  // MARK: - In-memory cache stubs

  struct StubCC: CryptoCompareSymbolLookup {
    var byContract: [String: String] = [:]
    var natives: Set<String> = []
    var all: Set<String> = []

    func symbol(forContract address: String) async -> String? {
      byContract[address.lowercased()]
    }
    func nativeSymbols() async -> Set<String> { natives }
    func allSymbols() async -> Set<String> { all }
  }

  struct StubBinance: BinancePairLookup {
    var pairs: Set<String> = []

    func hasUsdtPair(base symbol: String) async -> Bool {
      pairs.contains("\(symbol.uppercased())USDT")
    }
  }

  struct StubCG: LocalContractResolver {
    var byContract: [String: LocalContractMatch] = [:]

    func localContractMatch(chainId: Int, contractAddress: String) async -> LocalContractMatch? {
      byContract[contractAddress.lowercased()]
    }
  }

  // MARK: - Registry fixture (mirrors InstrumentRegistryContractTests)

  @MainActor
  final class HookCapture {
    var changedIds: [String] = []
  }

  @MainActor
  struct Subject {
    let repo: GRDBInstrumentRegistryRepository
    let hooks: HookCapture
  }

  @MainActor
  func makeSubject() throws -> Subject {
    let database = try ProfileIndexDatabase.openInMemory()
    let hooks = HookCapture()
    let repo = GRDBInstrumentRegistryRepository(
      database: database,
      onRecordChanged: { [hooks] id in Task { @MainActor in hooks.changedIds.append(id) } },
      onRecordDeleted: { _ in }
    )
    return Subject(repo: repo, hooks: hooks)
  }

  // MARK: - Fixtures

  private var rpl: Instrument {
    .crypto(
      chainId: 1, contractAddress: "0xd33526068d116ce69f19a9ee46f0bd304f21a51f",
      symbol: "RPL", name: "Rocket Pool", decimals: 18)
  }

  private var rplAddress: String { "0xd33526068d116ce69f19a9ee46f0bd304f21a51f" }

  private func reg(byId id: String, in repo: GRDBInstrumentRegistryRepository) async throws
    -> CryptoRegistration
  {
    let regs = try await repo.allCryptoRegistrations()
    return try #require(regs.first { $0.id == id })
  }

  // MARK: - Tests

  @Test("fills nil provider columns from the caches")
  func upgradesPartialMapping() async throws {
    let subject = try makeSubject()
    let repo = subject.repo
    let rpl = rpl
    try await repo.registerCrypto(
      rpl,
      mapping: CryptoProviderMapping(
        instrumentId: rpl.id, coingeckoId: "rocket-pool",
        cryptocompareSymbol: nil, binanceSymbol: nil))

    let catalogs = ProviderCatalogLookups(
      cryptoCompare: StubCC(byContract: [rplAddress: "RPL"]),
      binance: StubBinance(pairs: ["RPLUSDT"]),
      coinGecko: StubCG())
    await repo.reconcileProviderMappings(using: catalogs)

    let reg = try await reg(byId: rpl.id, in: repo)
    #expect(reg.mapping.coingeckoId == "rocket-pool")
    #expect(reg.mapping.cryptocompareSymbol == "RPL")
    #expect(reg.mapping.binanceSymbol == "RPLUSDT")
  }

  @Test("never downgrades a populated column and writes nothing when fully covered")
  func neverDowngrades() async throws {
    let subject = try makeSubject()
    let repo = subject.repo
    let hooks = subject.hooks
    let rpl = rpl
    try await repo.registerCrypto(
      rpl,
      mapping: CryptoProviderMapping(
        instrumentId: rpl.id, coingeckoId: "rocket-pool",
        cryptocompareSymbol: "RPL", binanceSymbol: "RPLUSDT"))
    try await Task.sleep(for: .milliseconds(50))
    hooks.changedIds.removeAll()

    // Caches offer DIFFERENT values; merge-only fill must ignore them.
    let catalogs = ProviderCatalogLookups(
      cryptoCompare: StubCC(byContract: [rplAddress: "XXX"]),
      binance: StubBinance(pairs: ["RPLUSDT"]),
      coinGecko: StubCG(
        byContract: [
          rplAddress: LocalContractMatch(
            coingeckoId: "other", symbol: "RPL", name: "Rocket Pool")
        ]))
    await repo.reconcileProviderMappings(using: catalogs)

    let reg = try await reg(byId: rpl.id, in: repo)
    #expect(reg.mapping.coingeckoId == "rocket-pool")
    #expect(reg.mapping.cryptocompareSymbol == "RPL")
    #expect(reg.mapping.binanceSymbol == "RPLUSDT")

    try await Task.sleep(for: .milliseconds(50))
    #expect(hooks.changedIds.isEmpty)
  }

  @Test("no sync churn when already fully covered")
  func noChurnWhenCovered() async throws {
    let subject = try makeSubject()
    let repo = subject.repo
    let hooks = subject.hooks
    let rpl = rpl
    try await repo.registerCrypto(
      rpl,
      mapping: CryptoProviderMapping(
        instrumentId: rpl.id, coingeckoId: "rocket-pool",
        cryptocompareSymbol: "RPL", binanceSymbol: "RPLUSDT"))
    try await Task.sleep(for: .milliseconds(50))
    hooks.changedIds.removeAll()

    let catalogs = ProviderCatalogLookups(
      cryptoCompare: StubCC(byContract: [rplAddress: "RPL"]),
      binance: StubBinance(pairs: ["RPLUSDT"]),
      coinGecko: StubCG(
        byContract: [
          rplAddress: LocalContractMatch(
            coingeckoId: "rocket-pool", symbol: "RPL", name: "Rocket Pool")
        ]))
    await repo.reconcileProviderMappings(using: catalogs)

    try await Task.sleep(for: .milliseconds(50))
    #expect(hooks.changedIds.isEmpty)
  }

  @Test("leaves a token unchanged when no cache knows it")
  func ignoresUnknownTokens() async throws {
    let subject = try makeSubject()
    let repo = subject.repo
    let rpl = rpl
    try await repo.registerCrypto(
      rpl,
      mapping: CryptoProviderMapping(
        instrumentId: rpl.id, coingeckoId: "rocket-pool",
        cryptocompareSymbol: nil, binanceSymbol: nil))

    let catalogs = ProviderCatalogLookups(
      cryptoCompare: StubCC(), binance: StubBinance(), coinGecko: StubCG())
    await repo.reconcileProviderMappings(using: catalogs)

    let reg = try await reg(byId: rpl.id, in: repo)
    #expect(reg.mapping.coingeckoId == "rocket-pool")
    #expect(reg.mapping.cryptocompareSymbol == nil)
    #expect(reg.mapping.binanceSymbol == nil)
  }

  @Test("fills native token from native symbols + binance pair")
  func nativeToken() async throws {
    let subject = try makeSubject()
    let repo = subject.repo
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    try await repo.registerCrypto(
      eth,
      mapping: CryptoProviderMapping(
        instrumentId: eth.id, coingeckoId: "ethereum",
        cryptocompareSymbol: nil, binanceSymbol: nil))

    let catalogs = ProviderCatalogLookups(
      cryptoCompare: StubCC(natives: ["ETH"]),
      binance: StubBinance(pairs: ["ETHUSDT"]),
      coinGecko: StubCG())
    await repo.reconcileProviderMappings(using: catalogs)

    let reg = try await reg(byId: eth.id, in: repo)
    #expect(reg.mapping.coingeckoId == "ethereum")
    #expect(reg.mapping.cryptocompareSymbol == "ETH")
    #expect(reg.mapping.binanceSymbol == "ETHUSDT")
  }

  @Test("idempotent — a second reconcile fires no writes")
  func idempotent() async throws {
    let subject = try makeSubject()
    let repo = subject.repo
    let hooks = subject.hooks
    let rpl = rpl
    try await repo.registerCrypto(
      rpl,
      mapping: CryptoProviderMapping(
        instrumentId: rpl.id, coingeckoId: "rocket-pool",
        cryptocompareSymbol: nil, binanceSymbol: nil))

    let catalogs = ProviderCatalogLookups(
      cryptoCompare: StubCC(byContract: [rplAddress: "RPL"]),
      binance: StubBinance(pairs: ["RPLUSDT"]),
      coinGecko: StubCG())
    await repo.reconcileProviderMappings(using: catalogs)
    try await Task.sleep(for: .milliseconds(50))
    hooks.changedIds.removeAll()

    await repo.reconcileProviderMappings(using: catalogs)
    try await Task.sleep(for: .milliseconds(50))
    #expect(hooks.changedIds.isEmpty)
  }

  @Test("a .spam row with a copied ticker is never given a provider symbol (#790)")
  func spamRowNotPoisoned() async throws {
    let subject = try makeSubject()
    let repo = subject.repo
    let hooks = subject.hooks
    // A spam ERC-20 impersonating Optimism: a different contract, but a
    // copied "OP" ticker and an all-nil mapping persisted at .spam by the
    // discovery actor. Reconcile must not attribute OPUSDT / OP from the
    // unverified ticker — that's the #790 poisoning the contract-confirmed
    // resolver path is built to prevent.
    let fakeOp = Instrument.crypto(
      chainId: 1, contractAddress: "0x000000000000000000000000000000000000dead",
      symbol: "OP", name: "Optimism", decimals: 18)
    try await repo.registerCrypto(
      fakeOp,
      mapping: CryptoProviderMapping(
        instrumentId: fakeOp.id, coingeckoId: nil,
        cryptocompareSymbol: nil, binanceSymbol: nil),
      forcingStatus: .spam)
    try await Task.sleep(for: .milliseconds(50))
    hooks.changedIds.removeAll()

    let catalogs = ProviderCatalogLookups(
      cryptoCompare: StubCC(byContract: ["0x000000000000000000000000000000000000dead": "OP"]),
      binance: StubBinance(pairs: ["OPUSDT"]),
      coinGecko: StubCG())
    await repo.reconcileProviderMappings(using: catalogs)

    // The row is returned by allCryptoRegistrations() (it's .spam, so the
    // Lookup guard does not drop it), so it must be explicitly skipped.
    let reg = try await reg(byId: fakeOp.id, in: repo)
    #expect(reg.mapping.coingeckoId == nil)
    #expect(reg.mapping.cryptocompareSymbol == nil)
    #expect(reg.mapping.binanceSymbol == nil)
    #expect(reg.pricingStatus == .spam)

    try await Task.sleep(for: .milliseconds(50))
    #expect(hooks.changedIds.isEmpty)
  }
}
