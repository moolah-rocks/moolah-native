import Foundation
import Testing

@testable import Moolah

@Suite("InvestmentStore")
@MainActor
struct InvestmentStoreTestsMoreExtra {

  private func makeDate(year: Int, month: Int, day: Int) -> Date {
    guard let date = Calendar.current.date(from: DateComponents(year: year, month: month, day: day))
    else { preconditionFailure("static gregorian DateComponents are always valid") }
    return date
  }

  private func makeValues(accountId: UUID, count: Int) -> [UUID: [InvestmentValue]] {
    let values = (0..<count).map { i in
      guard let date = Calendar.current.date(byAdding: .day, value: -i, to: Date())
      else { preconditionFailure("subtracting days from the current date is always valid") }
      return InvestmentValue(
        date: date,
        value: InstrumentAmount(
          quantity: Decimal(1000 + i * 10), instrument: .defaultTestInstrument)
      )
    }
    return [accountId: values]
  }

  @Test("Empty data produces empty chart data points")
  func testChartDataPointsEmpty() {
    let result = InvestmentChartData.merge(values: [], balances: [], period: .all)
    #expect(result.isEmpty)
  }

  // MARK: - Multi-instrument manual investment values

  @Test("Set value preserves USD instrument through store round-trip")
  func testSetValueWithUSDInstrument() async throws {
    let accountId = UUID()
    let (backend, _) = try TestBackend.create()
    let store = InvestmentStore(
      repository: backend.investments, conversionService: FakeConversionService.fixedRates([:]))
    let date = makeDate(year: 2024, month: 3, day: 15)
    let amount = InstrumentAmount(quantity: Decimal(5000), instrument: .USD)

    await store.setValue(accountId: accountId, date: date, value: amount)

    #expect(store.values.count == 1)
    #expect(store.values[0].value.instrument == .USD)
    #expect(store.values[0].value.quantity == Decimal(5000))
  }

  // MARK: - Cancellation

  @Test("loadPositions bails out deterministically mid-pagination when the task is cancelled")
  func testLoadPositionsHonoursCancellationDeterministic() async throws {
    let accountId = UUID()
    let (backend, _) = try TestBackend.create()
    let repo = CancellablePagingTransactionRepository(pageSize: 200)

    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: repo,
      conversionService: FakeConversionService.fixedRates([:])
    )

    let task = Task { @MainActor in
      await store.loadPositions(accountId: accountId)
    }

    // Wait until the repo has started serving its first page, then cancel
    // the task. The fix's cancellation check should short-circuit before
    // positions are published.
    await repo.waitForFirstFetch()
    task.cancel()
    await repo.releaseSecondFetch()
    await task.value

    #expect(store.positions.isEmpty)
    #expect(store.error == nil)
  }

  @Test("Different accounts can have values in different instruments")
  func testValuesWithDifferentInstrumentsPerAccount() async throws {
    let audAccount = UUID()
    let usdAccount = UUID()
    let (backend, database) = try TestBackend.create()
    let date = makeDate(year: 2024, month: 3, day: 15)
    // seed(investmentValues:) uses a single instrument per call, so seed each account separately
    // with its own instrument so the stored records retain the account's real currency.
    TestBackend.seed(
      investmentValues: [
        audAccount: [
          InvestmentValue(
            date: date,
            value: InstrumentAmount(quantity: Decimal(1000), instrument: .AUD))
        ]
      ],
      in: database,
      instrument: .AUD)
    TestBackend.seed(
      investmentValues: [
        usdAccount: [
          InvestmentValue(
            date: date,
            value: InstrumentAmount(quantity: Decimal(650), instrument: .USD))
        ]
      ],
      in: database,
      instrument: .USD)
    let store = InvestmentStore(
      repository: backend.investments, conversionService: FakeConversionService.fixedRates([:]))

    await store.loadValues(accountId: audAccount)
    #expect(store.values.count == 1)
    #expect(store.values[0].value.instrument == .AUD)

    await store.loadValues(accountId: usdAccount)
    #expect(store.values.count == 1)
    #expect(store.values[0].value.instrument == .USD)
  }

  // MARK: - Cancellation

  @Test("loadValues bails out of pagination when the task is cancelled")
  func testLoadValuesHonoursCancellation() async throws {
    // Seed enough values to span multiple pages so pagination would
    // otherwise keep looping past the cancellation point.
    let accountId = UUID()
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(
      investmentValues: makeValues(accountId: accountId, count: 450), in: database
    )
    let store = InvestmentStore(
      repository: backend.investments, conversionService: FakeConversionService.fixedRates([:]))

    // Run loadValues inside a task we cancel before it runs. The
    // cancellation flag is inherited, so the guard after the first
    // fetch should return without populating `values`.
    let task = Task { @MainActor in
      await store.loadValues(accountId: accountId)
    }
    task.cancel()
    await task.value

    // The cancellation guard fires after the first page returns, so
    // `values` must not be populated with the full dataset.
    #expect(
      store.values.count < 450,
      "Expected loadValues to stop paginating after cancellation, but got \(store.values.count) values"
    )
    #expect(store.error == nil, "Cancellation should not surface as an error")
  }

  @Test("loadPositions bails out of pagination when the task is cancelled")
  func testLoadPositionsHonoursCancellation() async throws {
    let accountId = UUID()
    let (backend, database) = try TestBackend.create()
    // Seed > 200 transactions so loadPositions would normally paginate.
    let transactions: [Transaction] = (0..<250).map { i in
      guard let date = Calendar.current.date(byAdding: .day, value: -i, to: Date())
      else { preconditionFailure("subtracting days from the current date is always valid") }
      return Transaction(
        date: date,
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: .defaultTestInstrument,
            quantity: Decimal(1), type: .income)
        ]
      )
    }
    _ = TestBackend.seed(transactions: transactions, in: database)

    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]))

    let task = Task { @MainActor in
      await store.loadPositions(accountId: accountId)
    }
    task.cancel()
    await task.value

    // When cancelled, positions must not be computed from a partial
    // fetch and written to the store.
    #expect(
      store.positions.isEmpty,
      "Expected positions to remain empty on cancellation, got \(store.positions.count)"
    )
    #expect(store.error == nil, "Cancellation should not surface as an error")
  }
}
