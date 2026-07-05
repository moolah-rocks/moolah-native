import Foundation
import Testing

@testable import Moolah

// Swift Testing's `@Test func foo()` is the documented idiom, and
// swift-format's `lineBreakBetweenDeclarationAttributes: false` keeps the
// attribute inline. Disable SwiftLint's `attributes` rule in this file so
// the formatter and the linter don't fight over the same layout.
// swiftlint:disable attributes

@Suite("ReportingStore — Part 2")
struct ReportingStoreTestsMore {
  let aud = Instrument.fiat(code: "AUD")

  @Test func capitalGainsSummary_taxAdjustmentValues_withLosses() {
    let summary = CapitalGainsSummary(
      shortTermGain: -200,
      longTermGain: 1000,
      totalGain: 800,
      eventCount: 3
    )

    let values = summary.asTaxAdjustmentValues(currency: aud)
    #expect(values.shortTerm.quantity == 0)
    #expect(values.longTerm.quantity == 1000)
    #expect(values.losses.quantity == 200)
  }

  @Test func capitalGainsSummary_cgtDiscount() {
    let summary = CapitalGainsSummary(
      shortTermGain: 0,
      longTermGain: 1000,
      totalGain: 1000,
      eventCount: 1
    )
    // 50% CGT discount on long-term gains
    #expect(summary.discountedLongTermGain == 500)
    #expect(summary.netCapitalGain == 500)
  }

  // MARK: - Multi-instrument profit/loss

  @Test @MainActor func loadProfitLoss_aggregatesMultipleStockInstruments() async throws {
    let (backend, database) = try TestBackend.create()
    let account = Account(
      id: UUID(), name: "Brokerage", type: .bank, instrument: .defaultTestInstrument
    )
    TestBackend.seed(accounts: [account], in: database)

    let bhp = Instrument(
      id: "ASX:BHP.AX", kind: .stock, name: "BHP", decimals: 0,
      ticker: "BHP.AX", exchange: "ASX", chainId: nil, contractAddress: nil)
    let cba = Instrument(
      id: "ASX:CBA.AX", kind: .stock, name: "CBA", decimals: 0,
      ticker: "CBA.AX", exchange: "ASX", chainId: nil, contractAddress: nil)
    try await TestBackend.register(bhp, in: backend)
    try await TestBackend.register(cba, in: backend)

    let buyBHP = Transaction(
      date: Date(),
      payee: "Buy BHP",
      legs: [
        TransactionLeg(
          accountId: account.id, instrument: aud, quantity: -4000, type: .trade),
        TransactionLeg(
          accountId: account.id, instrument: bhp, quantity: 100, type: .trade),
      ]
    )
    let buyCBA = Transaction(
      date: Date(),
      payee: "Buy CBA",
      legs: [
        TransactionLeg(
          accountId: account.id, instrument: aud, quantity: -5000, type: .trade),
        TransactionLeg(
          accountId: account.id, instrument: cba, quantity: 50, type: .trade),
      ]
    )
    TestBackend.seed(transactions: [buyBHP, buyCBA], in: database)

    // BHP worth $50/share → 5000, CBA worth $120/share → 6000
    let service = FakeConversionService.fixedRates(["ASX:BHP.AX": 50, "ASX:CBA.AX": 120])
    let store = ReportingStore(
      transactionRepository: backend.transactions,
      conversionService: service,
      profileCurrency: aud
    )

    await store.loadProfitLoss()

    #expect(store.profitLoss.count == 2)
    let bhpPL = try #require(store.profitLoss.first { $0.instrument.id == "ASX:BHP.AX" })
    let cbaPL = try #require(store.profitLoss.first { $0.instrument.id == "ASX:CBA.AX" })
    #expect(bhpPL.totalInvested == 4000)
    #expect(bhpPL.currentValue == 5000)
    #expect(cbaPL.totalInvested == 5000)
    #expect(cbaPL.currentValue == 6000)
  }

  @Test @MainActor func loadProfitLoss_tracksStockAndCryptoInSamePortfolio() async throws {
    let (backend, database) = try TestBackend.create()
    let account = Account(
      id: UUID(), name: "Hybrid", type: .bank, instrument: .defaultTestInstrument
    )
    TestBackend.seed(accounts: [account], in: database)

    let bhp = Instrument(
      id: "ASX:BHP.AX", kind: .stock, name: "BHP", decimals: 0,
      ticker: "BHP.AX", exchange: "ASX", chainId: nil, contractAddress: nil)
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
    )
    try await TestBackend.register(bhp, in: backend)
    try await TestBackend.register(eth, in: backend)

    let txns = [
      Transaction(
        date: Date(),
        payee: "Buy BHP",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: aud, quantity: -4000, type: .trade),
          TransactionLeg(
            accountId: account.id, instrument: bhp, quantity: 100, type: .trade),
        ]),
      Transaction(
        date: Date(),
        payee: "Buy ETH",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: aud, quantity: -2000, type: .trade),
          TransactionLeg(
            accountId: account.id, instrument: eth,
            quantity: dec("1.0"), type: .trade),
        ]),
    ]
    TestBackend.seed(transactions: txns, in: database)

    let service = FakeConversionService.fixedRates(["ASX:BHP.AX": 50, eth.id: 2500])
    let store = ReportingStore(
      transactionRepository: backend.transactions,
      conversionService: service,
      profileCurrency: aud
    )

    await store.loadProfitLoss()

    #expect(store.profitLoss.count == 2)
    let kinds = Set(store.profitLoss.map { $0.instrument.kind })
    #expect(kinds == [.stock, .cryptoToken])
  }

  @Test @MainActor func loadCategoryBalances_populatesIncomeAndExpense() async throws {
    let (backend, database) = try TestBackend.create()
    let account = Account(
      id: UUID(), name: "Checking", type: .bank, instrument: .defaultTestInstrument
    )
    let incomeCategory = Moolah.Category(id: UUID(), name: "Salary")
    let expenseCategory = Moolah.Category(id: UUID(), name: "Groceries")
    TestBackend.seed(accounts: [account], in: database)
    TestBackend.seed(categories: [incomeCategory, expenseCategory], in: database)

    let today = Date()
    TestBackend.seed(
      transactions: [
        Transaction(
          date: today,
          payee: "Employer",
          legs: [
            TransactionLeg(
              accountId: account.id, instrument: .defaultTestInstrument,
              quantity: 1000, type: .income, categoryId: incomeCategory.id)
          ]
        ),
        Transaction(
          date: today,
          payee: "Store",
          legs: [
            TransactionLeg(
              accountId: account.id, instrument: .defaultTestInstrument,
              quantity: -50, type: .expense, categoryId: expenseCategory.id)
          ]
        ),
      ],
      in: database
    )

    let store = ReportingStore(
      transactionRepository: backend.transactions,
      analysisRepository: backend.analysis,
      conversionService: FakeConversionService.fixedRates([:]),
      profileCurrency: .defaultTestInstrument
    )

    let from = try #require(Calendar.current.date(byAdding: .day, value: -1, to: today))
    let to = try #require(Calendar.current.date(byAdding: .day, value: 1, to: today))
    await store.loadCategoryBalances(dateRange: from...to)

    #expect(!store.isLoadingCategoryBalances)
    #expect(store.categoryBalancesError == nil)
    #expect(store.incomeBalances[incomeCategory.id]?.quantity == 1000)
    #expect(store.expenseBalances[expenseCategory.id]?.quantity == -50)
  }

  @Test @MainActor func loadCategoryBalances_populatesUncategorisedAndUnavailableFlags()
    async throws
  {
    let income = CategoryBalances(
      byCategory: [:],
      uncategorised: InstrumentAmount(quantity: 250, instrument: aud),
      hasUnavailableData: true
    )
    let expense = CategoryBalances(
      byCategory: [:],
      uncategorised: InstrumentAmount(quantity: -75, instrument: aud),
      hasUnavailableData: false
    )
    let repository = StubCategoryBalancesAnalysisRepository(income: income, expense: expense)
    let (backend, _) = try TestBackend.create()
    let store = ReportingStore(
      transactionRepository: backend.transactions,
      analysisRepository: repository,
      conversionService: FakeConversionService.fixedRates([:]),
      profileCurrency: aud
    )

    let today = Date()
    let from = try #require(Calendar.current.date(byAdding: .day, value: -1, to: today))
    let to = try #require(Calendar.current.date(byAdding: .day, value: 1, to: today))
    await store.loadCategoryBalances(dateRange: from...to)

    #expect(!store.isLoadingCategoryBalances)
    #expect(store.categoryBalancesError == nil)
    #expect(store.incomeUncategorised?.quantity == 250)
    #expect(store.expenseUncategorised?.quantity == -75)
    #expect(store.incomeHasUnavailableData == true)
    #expect(store.expenseHasUnavailableData == false)
  }

  @Test @MainActor func loadCategoryBalances_noUncategorisedLegs_leavesFieldsNilAndFalse()
    async throws
  {
    let empty = CategoryBalances(byCategory: [:], uncategorised: nil)
    let repository = StubCategoryBalancesAnalysisRepository(income: empty, expense: empty)
    let (backend, _) = try TestBackend.create()
    let store = ReportingStore(
      transactionRepository: backend.transactions,
      analysisRepository: repository,
      conversionService: FakeConversionService.fixedRates([:]),
      profileCurrency: aud
    )

    let today = Date()
    let from = try #require(Calendar.current.date(byAdding: .day, value: -1, to: today))
    let to = try #require(Calendar.current.date(byAdding: .day, value: 1, to: today))
    await store.loadCategoryBalances(dateRange: from...to)

    #expect(store.incomeUncategorised == nil)
    #expect(store.expenseUncategorised == nil)
    #expect(store.incomeHasUnavailableData == false)
    #expect(store.expenseHasUnavailableData == false)
  }
}
// swiftlint:enable attributes
