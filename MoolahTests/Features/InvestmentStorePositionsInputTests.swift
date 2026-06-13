import Foundation
import Testing

@testable import Moolah

@MainActor
@Suite("InvestmentStore positionsViewInput")
struct InvestmentStorePositionsInputTests {
  let aud = Instrument.AUD
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")

  @Test("input title is the account name and host currency is the account instrument")
  func inputCarriesIdentity() async throws {
    let (backend, _) = try TestBackend.create()
    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: backend.conversionService
    )
    let account = Account(
      name: "Brokerage", type: .investment, instrument: aud,
      valuationMode: .calculatedFromTrades)
    _ = try await backend.accounts.create(
      account, openingBalance: InstrumentAmount(quantity: 0, instrument: aud))
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(),
        legs: [
          TransactionLeg(accountId: account.id, instrument: bhp, quantity: 100, type: .trade),
          TransactionLeg(accountId: account.id, instrument: aud, quantity: -4_000, type: .trade),
        ]
      )
    )
    await store.loadAllData(account: account, profileCurrency: aud)

    let input = try await store.positionsViewInput(
      title: account.name, range: .threeMonths)

    #expect(input.title == "Brokerage")
    #expect(input.hostCurrency == aud)
    #expect(input.positions.contains(where: { $0.instrument == bhp }))
    let bhpRow = try #require(input.positions.first(where: { $0.instrument == bhp }))
    #expect(bhpRow.costBasis == InstrumentAmount(quantity: 4_000, instrument: aud))
  }

  /// Registers a crypto instrument with a coingecko-only provider mapping
  /// so writes against it satisfy `ensureInstrument`'s tightening (Task 14).
  private func registerCoingeckoOnly(
    _ instrument: Instrument, coingeckoId: String, in backend: CloudKitBackend
  ) async throws {
    try await backend.instrumentRegistryRepository.registerCrypto(
      instrument,
      mapping: CryptoProviderMapping(
        instrumentId: instrument.id, coingeckoId: coingeckoId,
        cryptocompareSymbol: nil, binanceSymbol: nil))
  }

  @Test("crypto-to-crypto swap shifts cost basis correctly")
  func swapShiftsCostBasis() async throws {
    let (backend, _) = try TestBackend.create()
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    let btc = Instrument.crypto(
      chainId: 0, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8)
    try await registerCoingeckoOnly(eth, coingeckoId: "ethereum", in: backend)
    try await registerCoingeckoOnly(btc, coingeckoId: "bitcoin", in: backend)

    // Use FixedConversionService so the swap-date rates are deterministic
    // (TestBackend's default conversion service may not have ETH/BTC fixtures).
    let conversionService = FixedConversionService(rates: [
      eth.id: Decimal(3_000),
      btc.id: Decimal(60_000),
    ])
    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: conversionService
    )
    let account = Account(
      name: "Crypto", type: .investment, instrument: aud,
      valuationMode: .calculatedFromTrades)
    _ = try await backend.accounts.create(
      account, openingBalance: InstrumentAmount(quantity: 0, instrument: aud))

    // Buy 4 ETH for 12,000 AUD on day 1 (10 days ago).
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(timeIntervalSinceNow: -86_400 * 10),
        legs: [
          TransactionLeg(accountId: account.id, instrument: eth, quantity: 4, type: .trade),
          TransactionLeg(accountId: account.id, instrument: aud, quantity: -12_000, type: .trade),
        ]
      )
    )
    // Swap 2 ETH → 0.1 BTC on day 5 (5 days ago).
    // After the swap, the engine should have:
    //   - ETH: 2 remaining @ 3000 AUD each → cost basis 6,000.
    //   - BTC: 0.1 lot @ 60,000 AUD each → cost basis 6,000.
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(timeIntervalSinceNow: -86_400 * 5),
        legs: [
          TransactionLeg(accountId: account.id, instrument: eth, quantity: -2, type: .trade),
          TransactionLeg(
            accountId: account.id, instrument: btc, quantity: dec("0.1"),
            type: .trade),
        ]
      )
    )

    await store.loadAllData(account: account, profileCurrency: aud)
    let input = try await store.positionsViewInput(title: account.name, range: .threeMonths)

    let ethRow = try #require(input.positions.first(where: { $0.instrument == eth }))
    let btcRow = try #require(input.positions.first(where: { $0.instrument == btc }))
    #expect(ethRow.costBasis == InstrumentAmount(quantity: 6_000, instrument: aud))
    #expect(btcRow.costBasis == InstrumentAmount(quantity: 6_000, instrument: aud))
  }

  @Test("same-asset ETH across chains rolls into one holding via the registry map")
  func crossChainEthRollsIntoOneHolding() async throws {
    let (backend, _) = try TestBackend.create()
    let ethMainnet = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    let ethOptimism = Instrument.crypto(
      chainId: 10, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    // Both chains' native ETH map to the same coingecko asset key, so the
    // holdings fold should collapse them into a single "ethereum" row.
    try await registerCoingeckoOnly(ethMainnet, coingeckoId: "ethereum", in: backend)
    try await registerCoingeckoOnly(ethOptimism, coingeckoId: "ethereum", in: backend)

    // Date-based fixed rates (effective from well before the earliest trade)
    // so the conversion exercises the `on date:` valuation-date threading
    // rather than a flat per-currency rate. The fold itself introduces no
    // conversions, so the held quantity is unaffected.
    let rateEffectiveFrom = Date(timeIntervalSinceNow: -86_400 * 365)
    let conversionService = DateBasedFixedConversionService(rates: [
      rateEffectiveFrom: [
        ethMainnet.id: Decimal(3_000),
        ethOptimism.id: Decimal(3_000),
      ]
    ])
    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: conversionService,
      instrumentRegistry: backend.instrumentRegistryRepository
    )
    let account = Account(
      name: "Crypto", type: .investment, instrument: aud,
      valuationMode: .calculatedFromTrades)
    _ = try await backend.accounts.create(
      account, openingBalance: InstrumentAmount(quantity: 0, instrument: aud))

    // Buy 3 ETH on mainnet and 2 ETH on Optimism — 5 ETH held in total.
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(timeIntervalSinceNow: -86_400 * 10),
        legs: [
          TransactionLeg(accountId: account.id, instrument: ethMainnet, quantity: 3, type: .trade),
          TransactionLeg(accountId: account.id, instrument: aud, quantity: -9_000, type: .trade),
        ]
      )
    )
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(timeIntervalSinceNow: -86_400 * 5),
        legs: [
          TransactionLeg(accountId: account.id, instrument: ethOptimism, quantity: 2, type: .trade),
          TransactionLeg(accountId: account.id, instrument: aud, quantity: -6_000, type: .trade),
        ]
      )
    )

    let input = try await store.loadAndBuildPositionsInput(
      account: account, profileCurrency: aud, range: .threeMonths)

    let ethHoldings = input.assetHoldings.filter { $0.id == "ethereum" }
    let ethHolding = try #require(ethHoldings.first)
    #expect(ethHoldings.count == 1)
    #expect(ethHolding.quantity == Decimal(5))
  }

  @Test("loadAndBuildPositionsInput loads store state and returns built input")
  func loadAndBuildPositionsInputCoordinatesBothSteps() async throws {
    let (backend, _) = try TestBackend.create()
    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: backend.conversionService
    )
    let account = Account(
      name: "Brokerage", type: .investment, instrument: aud,
      valuationMode: .calculatedFromTrades)
    _ = try await backend.accounts.create(
      account, openingBalance: InstrumentAmount(quantity: 0, instrument: aud))
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(),
        legs: [
          TransactionLeg(accountId: account.id, instrument: bhp, quantity: 100, type: .trade),
          TransactionLeg(accountId: account.id, instrument: aud, quantity: -4_000, type: .trade),
        ]
      )
    )

    let input = try await store.loadAndBuildPositionsInput(
      account: account, profileCurrency: aud, range: .threeMonths)

    // Result reflects the second-step output, with the account name as title.
    #expect(input.title == "Brokerage")
    #expect(input.hostCurrency == aud)
    #expect(input.positions.contains(where: { $0.instrument == bhp }))

    // Store state was populated by the first-step `loadAllData` call.
    #expect(store.loadedAccountId == account.id)
    #expect(store.loadedHostCurrency == aud)
    #expect(store.positions.contains(where: { $0.instrument == bhp }))
  }
}
