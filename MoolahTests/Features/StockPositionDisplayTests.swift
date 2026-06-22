import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("InvestmentStore — Stock Positions")
@MainActor
struct StockPositionDisplayTests {
  let aud = Instrument.fiat(code: "AUD")
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let cba = Instrument.stock(ticker: "CBA.AX", exchange: "ASX", name: "CBA")

  private func dateString(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return formatter.string(from: date)
  }

  @Test
  func loadPositionsComputesFromLegs() async throws {
    let accountId = UUID()
    let (backend, database) = try TestBackend.create()
    try await TestBackend.register(bhp, in: backend)
    try await TestBackend.register(cba, in: backend)
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Invest", type: .investment, instrument: .defaultTestInstrument)
      ], in: database)

    // Seed a buy trade: -6345 AUD, +150 BHP
    let buyDate = try #require(
      Calendar.current.date(from: DateComponents(year: 2024, month: 6, day: 15)))
    TestBackend.seed(
      transactions: [
        Transaction(
          id: UUID(),
          date: buyDate,
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: aud, quantity: dec("-6345.00"),
              type: .transfer),
            TransactionLeg(
              accountId: accountId, instrument: bhp, quantity: Decimal(150), type: .transfer),
          ]
        )
      ], in: database)

    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:])
    )
    await store.loadPositions(accountId: accountId)

    #expect(store.positions.count == 2)  // AUD + BHP

    let bhpPosition = try #require(store.positions.first { $0.instrument == bhp })
    #expect(bhpPosition.quantity == Decimal(150))

    let audPosition = try #require(store.positions.first { $0.instrument == aud })
    #expect(audPosition.quantity == dec("-6345.00"))
  }

  @Test
  func valuedPositionsIncludeMarketValue() async throws {
    let accountId = UUID()
    let today = Date()
    let dateKey = dateString(today)

    // Cache caps "today" → yesterday — see `Shared/PriceCacheCap.swift`.
    let yKey = dateString(today.addingTimeInterval(-86400))
    let stockClient = FixedStockPriceClient(responses: [
      "BHP.AX": StockPriceResponse(
        instrument: .AUD, prices: [dateKey: dec("45.00"), yKey: dec("45.00")])
    ])
    let cacheDatabase = try ProfileIndexDatabase.openInMemory()
    // Pin to UTC — `dateString` / `today.addingTimeInterval(-86400)`
    // build the fixture's `YYYY-MM-DD` labels in UTC, so the cap must
    // resolve "yesterday" in UTC too for the lookup to match.
    let utc = try #require(TimeZone(identifier: "UTC"))
    let stockService = StockPriceService(
      client: stockClient, database: cacheDatabase, timeZone: utc)
    let rateClient = FixedRateClient(rates: [:])
    let rateService = ExchangeRateService(
      client: rateClient, database: cacheDatabase, timeZone: utc)
    let conversionService = FullConversionService(
      exchangeRates: rateService,
      stockPrices: stockService
    )

    let (backend, database) = try TestBackend.create()
    try await TestBackend.register(bhp, in: backend)
    try await TestBackend.register(cba, in: backend)
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Invest", type: .investment, instrument: .defaultTestInstrument)
      ], in: database)
    TestBackend.seed(
      transactions: [
        Transaction(
          id: UUID(),
          date: today,
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: aud, quantity: dec("-6345.00"),
              type: .transfer),
            TransactionLeg(
              accountId: accountId, instrument: bhp, quantity: Decimal(150), type: .transfer),
          ]
        )
      ], in: database)

    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: conversionService
    )
    await store.loadPositions(accountId: accountId)
    await store.valuatePositions(profileCurrency: aud, on: today)

    let bhpValued = try #require(store.valuedPositions.first { $0.instrument == bhp })
    // 150 shares * $45.00 = $6,750.00
    #expect(bhpValued.value?.quantity == dec("6750.00"))
  }

  @Test
  func totalPortfolioValueSumsAllPositions() async throws {
    let accountId = UUID()
    let today = Date()

    let conversionService = try makeTotalPortfolioConversionService(today: today)
    let (backend, database) = try TestBackend.create()
    try await TestBackend.register(bhp, in: backend)
    try await TestBackend.register(cba, in: backend)
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Invest", type: .investment, instrument: .defaultTestInstrument)
      ], in: database)
    TestBackend.seed(
      transactions: buyBhpAndCbaTransactions(accountId: accountId, date: today), in: database)

    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: conversionService
    )
    await store.loadPositions(accountId: accountId)
    await store.valuatePositions(profileCurrency: aud, on: today)

    // Cash: -6345 - 2400 = -8745 AUD (negative = cash spent)
    // BHP: 150 * 45.00 = 6750 AUD
    // CBA: 20 * 120.00 = 2400 AUD
    // Total: -8745 + 6750 + 2400 = 405 AUD
    #expect(store.totalPortfolioValue == dec("405.00"))
  }

  private func makeTotalPortfolioConversionService(today: Date) throws -> FullConversionService {
    let dateKey = dateString(today)
    // Cache caps "today" → yesterday — see `Shared/PriceCacheCap.swift`.
    let yKey = dateString(today.addingTimeInterval(-86400))
    let stockClient = FixedStockPriceClient(responses: [
      "BHP.AX": StockPriceResponse(
        instrument: .AUD, prices: [dateKey: dec("45.00"), yKey: dec("45.00")]),
      "CBA.AX": StockPriceResponse(
        instrument: .AUD, prices: [dateKey: dec("120.00"), yKey: dec("120.00")]),
    ])
    let database = try ProfileIndexDatabase.openInMemory()
    // Pin to UTC — same rationale as `valuedPositionsIncludeMarketValue`.
    let utc = try #require(TimeZone(identifier: "UTC"))
    let stockService = StockPriceService(
      client: stockClient, database: database, timeZone: utc)
    let rateClient = FixedRateClient(rates: [:])
    let rateService = ExchangeRateService(
      client: rateClient, database: database, timeZone: utc)
    return FullConversionService(
      exchangeRates: rateService,
      stockPrices: stockService
    )
  }

  private func buyBhpAndCbaTransactions(accountId: UUID, date: Date) -> [Transaction] {
    [
      // Buy 150 BHP for 6345 AUD
      Transaction(
        id: UUID(), date: date,
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: aud, quantity: dec("-6345.00"),
            type: .transfer),
          TransactionLeg(
            accountId: accountId, instrument: bhp, quantity: Decimal(150), type: .transfer),
        ]),
      // Buy 20 CBA for 2400 AUD
      Transaction(
        id: UUID(), date: date,
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: aud, quantity: dec("-2400.00"),
            type: .transfer),
          TransactionLeg(
            accountId: accountId, instrument: cba, quantity: Decimal(20), type: .transfer),
        ]),
    ]
  }

  /// Per Rule 11 in `guides/INSTRUMENT_CONVERSION_GUIDE.md`: when a
  /// position's conversion fails, the aggregate `totalPortfolioValue`
  /// must be marked unavailable (nil) — we must not display a partial
  /// sum as the portfolio total. Per-position valuations still render
  /// individually with `marketValue == nil` for the failing one.
  @Test
  func totalPortfolioValueIsNilWhenAnyPositionConversionFails() async throws {
    let accountId = UUID()
    let today = Date()

    let conversionService = FakeConversionService.failingInstruments(
      [cba.id],
      rates: [bhp.id: Decimal(45), cba.id: Decimal(120)]
    )

    let (backend, database) = try TestBackend.create()
    try await TestBackend.register(bhp, in: backend)
    try await TestBackend.register(cba, in: backend)
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Invest", type: .investment, instrument: .defaultTestInstrument)
      ], in: database)
    TestBackend.seed(
      transactions: [
        Transaction(
          id: UUID(), date: today,
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: aud, quantity: dec("-6345.00"),
              type: .transfer),
            TransactionLeg(
              accountId: accountId, instrument: bhp, quantity: Decimal(150), type: .transfer),
          ]),
        Transaction(
          id: UUID(), date: today,
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: aud, quantity: dec("-2400.00"),
              type: .transfer),
            TransactionLeg(
              accountId: accountId, instrument: cba, quantity: Decimal(20), type: .transfer),
          ]),
      ], in: database)

    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: conversionService
    )
    await store.loadPositions(accountId: accountId)
    await store.valuatePositions(profileCurrency: aud, on: today)

    // Aggregate is unavailable — one position failed.
    #expect(store.totalPortfolioValue == nil)
    // Per-position rendering still works for the convertible BHP.
    let bhpValued = store.valuedPositions.first { $0.instrument == bhp }
    #expect(bhpValued?.value?.quantity == dec("6750"))
    // And the failing position is rendered with nil value so the
    // view can show "Unavailable" on that row.
    let cbaValued = store.valuedPositions.first { $0.instrument == cba }
    #expect(cbaValued != nil)
    #expect(cbaValued?.value == nil)
    // Error state is surfaced so a retry affordance can be shown.
    #expect(store.error != nil)
  }
}
