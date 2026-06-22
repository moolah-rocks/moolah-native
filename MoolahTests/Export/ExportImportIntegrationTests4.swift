import Foundation
import Testing

@testable import Moolah

@Suite("Export/Import File Integration")
@MainActor
struct ExportImportIntegrationTests4 {

  private let instrument = Instrument.defaultTestInstrument

  private func makeTempFileURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("moolah-test-\(UUID().uuidString).json")
  }

  @Test("round-trip preserves fiat, stock, and crypto instruments across accounts, legs, earmarks")
  func multiCurrencyRoundTrip() async throws {
    let aud = Instrument.AUD
    let usd = Instrument.USD
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)

    let (backend, _) = try TestBackend.create(instrument: aud)
    // ensureInstrument now refuses to write an unmapped crypto leg, so
    // register ETH with a provider mapping before seeding the crypto income
    // transaction below.
    try await backend.instrumentRegistryRepository.registerCrypto(
      eth,
      mapping: CryptoProviderMapping(
        instrumentId: eth.id, coingeckoId: "ethereum",
        cryptocompareSymbol: nil, binanceSymbol: nil))
    let seeded = try await seedMultiCurrencyBackend(
      backend: backend, aud: aud, usd: usd, bhp: bhp, eth: eth)

    let tempURL = makeTempFileURL()
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let profile = Profile(
      label: "Multi-Currency Profile",
      currencyCode: aud.id,
      financialYearStartMonth: 7
    )
    let coordinator = ExportCoordinator()
    try await coordinator.exportToFile(url: tempURL, backend: backend, profile: profile)

    // Serialized JSON must list all four instruments for the importer to rehydrate them
    let exportedJSON = try Data(contentsOf: tempURL)
    let decoded = try JSONDecoder.exportDecoder.decode(ExportedData.self, from: exportedJSON)
    let exportedInstrumentIds = Set(decoded.instruments.map(\.id))
    #expect(exportedInstrumentIds == [aud.id, usd.id, bhp.id, eth.id])

    // Instrument identity lives on the shared profile-index registry;
    // the import registers the non-fiat BHP / ETH there and the
    // verification backend reads through the same instance.
    let freshDatabase = try ProfileDatabase.openInMemory()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    _ = try await coordinator.importFromFile(
      url: tempURL, database: freshDatabase, instrumentRegistrar: registry)
    let freshBackend = CloudKitBackend(
      database: freshDatabase,
      instrument: aud,
      profileLabel: profile.label,
      conversionService: FakeConversionService.fixedRates([:]),
      instrumentRegistry: registry
    )

    try await verifyMultiCurrencyRoundTrip(
      freshBackend: freshBackend,
      seeded: seeded,
      instruments: MultiCurrencyInstruments(aud: aud, usd: usd, bhp: bhp, eth: eth))
  }

  private struct SeededMultiCurrency {
    let audAccountId: UUID
    let usdAccountId: UUID
    let stockAccountId: UUID
    let cryptoAccountId: UUID
    let usdEarmarkId: UUID
  }

  private struct MultiCurrencyInstruments {
    let aud: Instrument
    let usd: Instrument
    let bhp: Instrument
    let eth: Instrument
  }

  private func seedMultiCurrencyBackend(
    backend: CloudKitBackend, aud: Instrument, usd: Instrument, bhp: Instrument, eth: Instrument
  ) async throws -> SeededMultiCurrency {
    let instruments = MultiCurrencyInstruments(aud: aud, usd: usd, bhp: bhp, eth: eth)
    let accounts = try await seedMultiCurrencyAccounts(
      backend: backend, instruments: instruments)
    let earmark = try await seedMultiCurrencyEarmark(backend: backend, usd: usd)
    try await seedMultiCurrencyTransactions(
      backend: backend, accounts: accounts, earmark: earmark, instruments: instruments)
    return SeededMultiCurrency(
      audAccountId: accounts.aud.id,
      usdAccountId: accounts.usd.id,
      stockAccountId: accounts.stock.id,
      cryptoAccountId: accounts.crypto.id,
      usdEarmarkId: earmark.usdEarmark.id)
  }

  private struct MultiCurrencyAccounts {
    let aud: Account
    let usd: Account
    let stock: Account
    let crypto: Account
  }

  private func seedMultiCurrencyAccounts(
    backend: CloudKitBackend, instruments: MultiCurrencyInstruments
  ) async throws -> MultiCurrencyAccounts {
    let audAccount = try await backend.accounts.create(
      Account(name: "Checking AUD", type: .bank, instrument: instruments.aud),
      openingBalance: InstrumentAmount(
        quantity: dec("1000.00"), instrument: instruments.aud))
    let usdAccount = try await backend.accounts.create(
      Account(name: "USD Travel", type: .bank, instrument: instruments.usd),
      openingBalance: InstrumentAmount(
        quantity: dec("200.00"), instrument: instruments.usd))
    let stockAccount = try await backend.accounts.create(
      Account(name: "Brokerage", type: .investment, instrument: instruments.bhp),
      openingBalance: InstrumentAmount(
        quantity: dec("10"), instrument: instruments.bhp))
    let cryptoAccount = try await backend.accounts.create(
      Account(name: "Crypto Wallet", type: .asset, instrument: instruments.eth),
      openingBalance: InstrumentAmount(
        quantity: dec("0.5"), instrument: instruments.eth))
    return MultiCurrencyAccounts(
      aud: audAccount, usd: usdAccount, stock: stockAccount, crypto: cryptoAccount)
  }

  private struct MultiCurrencyEarmark {
    let usdEarmark: Earmark
    let foodCategoryId: UUID
  }

  private func seedMultiCurrencyEarmark(
    backend: CloudKitBackend, usd: Instrument
  ) async throws -> MultiCurrencyEarmark {
    let food = try await backend.categories.create(Category(name: "Food"))
    let usdEarmark = try await backend.earmarks.create(
      Earmark(
        name: "US Trip", instrument: usd,
        savingsGoal: InstrumentAmount(quantity: dec("500.00"), instrument: usd)))
    try await backend.earmarks.setBudget(
      earmarkId: usdEarmark.id,
      categoryId: food.id,
      amount: InstrumentAmount(quantity: dec("50.00"), instrument: usd))
    return MultiCurrencyEarmark(usdEarmark: usdEarmark, foodCategoryId: food.id)
  }

  private func seedMultiCurrencyTransactions(
    backend: CloudKitBackend,
    accounts: MultiCurrencyAccounts,
    earmark: MultiCurrencyEarmark,
    instruments: MultiCurrencyInstruments
  ) async throws {
    let aud = instruments.aud
    let usd = instruments.usd
    let bhp = instruments.bhp
    let eth = instruments.eth
    // Expense in USD, tagged to the USD earmark
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(), payee: "NYC coffee",
        legs: [
          TransactionLeg(
            accountId: accounts.usd.id, instrument: usd,
            quantity: dec("-4.50"), type: .expense,
            categoryId: earmark.foodCategoryId, earmarkId: earmark.usdEarmark.id)
        ]))
    // Cross-instrument investment transfer (AUD -> BHP.AX)
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(), payee: "Stock purchase",
        legs: [
          TransactionLeg(
            accountId: accounts.aud.id, instrument: aud,
            quantity: dec("-500.00"), type: .transfer),
          TransactionLeg(
            accountId: accounts.stock.id, instrument: bhp,
            quantity: dec("5"), type: .transfer),
        ]))
    // Crypto income
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(), payee: "Staking reward",
        legs: [
          TransactionLeg(
            accountId: accounts.crypto.id, instrument: eth,
            quantity: dec("0.05"), type: .income)
        ]))
  }

  private func verifyMultiCurrencyRoundTrip(
    freshBackend: CloudKitBackend,
    seeded: SeededMultiCurrency,
    instruments: MultiCurrencyInstruments
  ) async throws {
    let aud = instruments.aud
    let usd = instruments.usd
    let bhp = instruments.bhp
    let eth = instruments.eth
    // Accounts: each should come back on its original instrument, with its primary position
    let accounts = try await freshBackend.accounts.fetchAll()
    let accountById = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })

    let fetchedAud = try #require(accountById[seeded.audAccountId])
    #expect(fetchedAud.instrument == aud)
    #expect(fetchedAud.positions.contains { $0.instrument == aud })

    let fetchedUsd = try #require(accountById[seeded.usdAccountId])
    #expect(fetchedUsd.instrument == usd)
    #expect(fetchedUsd.positions.contains { $0.instrument == usd })

    let fetchedStock = try #require(accountById[seeded.stockAccountId])
    #expect(fetchedStock.instrument == bhp)
    let bhpPosition = fetchedStock.positions.first { $0.instrument == bhp }
    #expect(bhpPosition?.instrument.kind == .stock)
    #expect(bhpPosition?.instrument.exchange == "ASX")
    #expect(bhpPosition?.instrument.ticker == "BHP.AX")

    let fetchedCrypto = try #require(accountById[seeded.cryptoAccountId])
    #expect(fetchedCrypto.instrument == eth)
    let ethPosition = fetchedCrypto.positions.first { $0.instrument == eth }
    #expect(ethPosition?.instrument.kind == .cryptoToken)
    #expect(ethPosition?.instrument.chainId == 1)
    #expect(ethPosition?.instrument.decimals == 18)

    // Earmarks: USD earmark must stay on USD, not collapse to profile AUD
    let earmarks = try await freshBackend.earmarks.fetchAll()
    let fetchedEarmark = try #require(earmarks.first { $0.id == seeded.usdEarmarkId })
    #expect(fetchedEarmark.instrument == usd)
    #expect(fetchedEarmark.savingsGoal?.instrument == usd)

    let budgetItems = try await freshBackend.earmarks.fetchBudget(earmarkId: seeded.usdEarmarkId)
    #expect(budgetItems.first?.amount.instrument == usd)

    // Transaction legs: each leg must retain its own instrument (fiat, stock, or crypto)
    let txnPage = try await freshBackend.transactions.fetch(
      filter: TransactionFilter(), page: 0, pageSize: 100)
    let legInstruments = Set(txnPage.transactions.flatMap { $0.legs.map(\.instrument) })
    #expect(legInstruments == [aud, usd, bhp, eth])

    let stockLeg = txnPage.transactions
      .flatMap(\.legs)
      .first { $0.instrument.kind == .stock }
    #expect(stockLeg?.instrument.ticker == "BHP.AX")

    let cryptoLeg = txnPage.transactions
      .flatMap(\.legs)
      .first { $0.instrument.kind == .cryptoToken }
    #expect(cryptoLeg?.instrument.chainId == 1)
    #expect(cryptoLeg?.instrument.decimals == 18)
  }
}
