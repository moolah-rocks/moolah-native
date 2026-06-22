import Foundation
import Testing

@testable import Moolah

@Suite("InvestmentStore")
@MainActor
struct InvestmentStoreTests {

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

  @Test("Load values populates values array")
  func testLoadValues() async throws {
    let accountId = UUID()
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(
      investmentValues: makeValues(accountId: accountId, count: 3), in: database
    )
    let store = InvestmentStore(
      repository: backend.investments, conversionService: FakeConversionService.fixedRates([:]))

    await store.loadValues(accountId: accountId)

    #expect(store.values.count == 3)
    #expect(store.isLoading == false)
    #expect(store.error == nil)
  }

  @Test("Load values with reset clears existing values")
  func testLoadValuesReset() async throws {
    let accountId = UUID()
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(
      investmentValues: makeValues(accountId: accountId, count: 5), in: database
    )
    let store = InvestmentStore(
      repository: backend.investments, conversionService: FakeConversionService.fixedRates([:]))

    await store.loadValues(accountId: accountId)
    #expect(store.values.count == 5)

    // Reset with new empty account
    await store.loadValues(accountId: UUID())
    #expect(store.values.isEmpty)
  }

  @Test("Set value adds to list and re-sorts")
  func testSetValue() async throws {
    let accountId = UUID()
    let (backend, _) = try TestBackend.create()
    let store = InvestmentStore(
      repository: backend.investments, conversionService: FakeConversionService.fixedRates([:]))

    let date = makeDate(year: 2024, month: 3, day: 15)
    let amount = InstrumentAmount(
      quantity: dec("125000.00"), instrument: .defaultTestInstrument)

    await store.setValue(accountId: accountId, date: date, value: amount)

    #expect(store.values.count == 1)
    #expect(store.values[0].date == date)
    #expect(store.values[0].value.quantity == dec("125000.00"))
  }

  @Test("Set value upserts existing date")
  func testSetValueUpserts() async throws {
    let accountId = UUID()
    let date = makeDate(year: 2024, month: 3, day: 15)
    let initialValues: [UUID: [InvestmentValue]] = [
      accountId: [
        InvestmentValue(
          date: date,
          value: InstrumentAmount(
            quantity: dec("1000.00"), instrument: .defaultTestInstrument))
      ]
    ]
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(investmentValues: initialValues, in: database)
    let store = InvestmentStore(
      repository: backend.investments, conversionService: FakeConversionService.fixedRates([:]))

    await store.loadValues(accountId: accountId)
    #expect(store.values.count == 1)

    let newAmount = InstrumentAmount(
      quantity: dec("2000.00"), instrument: .defaultTestInstrument)
    await store.setValue(accountId: accountId, date: date, value: newAmount)

    #expect(store.values.count == 1)
    #expect(store.values[0].value.quantity == dec("2000.00"))
  }

  @Test("Set value upserts in-memory when dates have different times on same day")
  func testSetValueUpsertsInMemoryWithDifferentTimes() async throws {
    let accountId = UUID()
    let morning = try #require(
      Calendar.current.date(
        from: DateComponents(year: 2024, month: 3, day: 15, hour: 9, minute: 0)))
    let initialValues: [UUID: [InvestmentValue]] = [
      accountId: [
        InvestmentValue(
          date: morning,
          value: InstrumentAmount(
            quantity: dec("1000.00"), instrument: .defaultTestInstrument))
      ]
    ]
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(investmentValues: initialValues, in: database)
    let store = InvestmentStore(
      repository: backend.investments, conversionService: FakeConversionService.fixedRates([:]))

    await store.loadValues(accountId: accountId)
    #expect(store.values.count == 1)

    let evening = try #require(
      Calendar.current.date(
        from: DateComponents(year: 2024, month: 3, day: 15, hour: 18, minute: 30)))
    let newAmount = InstrumentAmount(
      quantity: dec("2000.00"), instrument: .defaultTestInstrument)
    await store.setValue(accountId: accountId, date: evening, value: newAmount)

    #expect(store.values.count == 1, "Expected upsert but got duplicate entries in store")
    #expect(store.values[0].value.quantity == dec("2000.00"))
  }

  @Test("Remove value removes from list")
  func testRemoveValue() async throws {
    let accountId = UUID()
    let date = makeDate(year: 2024, month: 3, day: 15)
    let initialValues: [UUID: [InvestmentValue]] = [
      accountId: [
        InvestmentValue(
          date: date,
          value: InstrumentAmount(
            quantity: dec("1000.00"), instrument: .defaultTestInstrument))
      ]
    ]
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(investmentValues: initialValues, in: database)
    let store = InvestmentStore(
      repository: backend.investments, conversionService: FakeConversionService.fixedRates([:]))

    await store.loadValues(accountId: accountId)
    #expect(store.values.count == 1)

    await store.removeValue(accountId: accountId, date: date)
    #expect(store.values.isEmpty)
  }

  @Test("Remove value handles error gracefully")
  func testRemoveNonExistent() async throws {
    let (backend, _) = try TestBackend.create()
    let store = InvestmentStore(
      repository: backend.investments, conversionService: FakeConversionService.fixedRates([:]))

    await store.removeValue(accountId: UUID(), date: Date())

    #expect(store.error != nil)
  }

  // Cross-store fan-out to `AccountStore` happens via `AccountStore`'s
  // `investmentRepository.observeAllValues()` subscription. See
  // `AccountStoreSyncRefreshTests.investmentValueWriteReachesAccountStore`.

  // MARK: - Daily Balances
}
