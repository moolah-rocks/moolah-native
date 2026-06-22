import Foundation
import Testing

@testable import Moolah

@Suite("TransactionStore/CreateDefaults")
@MainActor
struct TransactionStoreCreateDefaultsTests {
  private let accountId = UUID()

  // MARK: - createDefault

  @Test
  func testCreateDefaultUsesFilterAccountId() async throws {
    let filterAccountId = UUID()
    let fallbackAccountId = UUID()
    let (backend, _) = try TestBackend.create()
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(accountId: filterAccountId))

    let created = await store.createDefault(
      accountId: filterAccountId,
      fallbackAccountId: fallbackAccountId,
      instrument: Instrument.defaultTestInstrument
    )

    #expect(created != nil)
    #expect(created?.accountIds.contains(filterAccountId) == true)
  }

  @Test
  func testCreateDefaultFallsBackToFirstAccount() async throws {
    let fallbackAccountId = UUID()
    let (backend, _) = try TestBackend.create()
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter())

    let created = await store.createDefault(
      accountId: nil,
      fallbackAccountId: fallbackAccountId,
      instrument: Instrument.defaultTestInstrument
    )

    #expect(created != nil)
    #expect(created?.accountIds.contains(fallbackAccountId) == true)
  }

  @Test
  func testCreateDefaultSetsExpenseTypeAndZeroAmount() async throws {
    let (backend, _) = try TestBackend.create()
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter())

    let created = await store.createDefault(
      accountId: accountId,
      fallbackAccountId: nil,
      instrument: Instrument.defaultTestInstrument
    )

    #expect(created != nil)
    #expect(created?.legs.first?.type ?? .expense == .expense)
    #expect(created?.legs.first?.quantity == 0)
    #expect(created?.legs.first?.instrument == Instrument.defaultTestInstrument)
    #expect(created?.payee?.isEmpty == true)
  }

  @Test
  func testCreateDefaultReturnsNilOnFailure() async throws {
    // Use an error-injecting repository to force a failure
    let failingStore = TransactionStore(
      repository: FailingTransactionRepository(),
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument
    )

    let result = await failingStore.createDefault(
      accountId: accountId,
      fallbackAccountId: nil,
      instrument: Instrument.defaultTestInstrument
    )

    #expect(result == nil)
    #expect(failingStore.error != nil)
  }

  // MARK: - createDefaultScheduled

  @Test
  func testCreateDefaultScheduledSetsMonthlyRecurrence() async throws {
    let (backend, _) = try TestBackend.create()
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(scheduled: .scheduledOnly))

    let created = await store.createDefaultScheduled(
      accountId: accountId,
      fallbackAccountId: nil,
      instrument: Instrument.defaultTestInstrument
    )

    #expect(created != nil)
    #expect(created?.isScheduled == true)
    #expect(created?.recurPeriod == .month)
    #expect(created?.recurEvery == 1)
    #expect(created?.legs.first?.type == .expense)
    #expect(created?.legs.first?.quantity == 0)
    #expect(created?.accountIds.contains(accountId) == true)
    #expect(created?.payee?.isEmpty == true)
  }

  @Test
  func testCreateDefaultScheduledFallsBackToFirstAccount() async throws {
    let fallbackAccountId = UUID()
    let (backend, _) = try TestBackend.create()
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(scheduled: .scheduledOnly))

    let created = await store.createDefaultScheduled(
      accountId: nil,
      fallbackAccountId: fallbackAccountId,
      instrument: Instrument.defaultTestInstrument
    )

    #expect(created != nil)
    #expect(created?.isScheduled == true)
    #expect(created?.accountIds.contains(fallbackAccountId) == true)
  }

  @Test
  func testCreateDefaultScheduledReturnsNilWhenNoAccount() async throws {
    let (backend, _) = try TestBackend.create()
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument
    )

    let result = await store.createDefaultScheduled(
      accountId: nil,
      fallbackAccountId: nil,
      instrument: Instrument.defaultTestInstrument
    )

    #expect(result == nil)
  }

  @Test
  func testCreateDefaultScheduledReturnsNilOnFailure() async throws {
    let failingStore = TransactionStore(
      repository: FailingTransactionRepository(),
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument
    )

    let result = await failingStore.createDefaultScheduled(
      accountId: accountId,
      fallbackAccountId: nil,
      instrument: Instrument.defaultTestInstrument
    )

    #expect(result == nil)
    #expect(failingStore.error != nil)
  }
}
