import Foundation
import Testing

@testable import Moolah

@Suite("AccountStore -- Conversion")
@MainActor
struct AccountStoreConversionTests {

  @Test
  func singleCurrencyAccountPositions() async throws {
    let accountId = UUID()
    let account = Account(
      id: accountId, name: "Bank", type: .bank, instrument: .defaultTestInstrument)
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(accounts: [account], in: database)

    let transaction = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: .AUD,
          quantity: dec("1000.00"),
          type: .openingBalance
        )
      ]
    )
    TestBackend.seed(transactions: [transaction], in: database)

    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument
    )
    // Quantity comes from storage (Int64 scaled); poll the settled snapshot.
    await expectEventually("single AUD position settles") {
      let positions = store.positions(for: accountId)
      return positions.count == 1
        && positions.first?.instrument == .AUD
        && positions.first?.quantity == dec("1000.00")
    }
  }

  @Test
  func multiCurrencyAccountShowsMultiplePositions() async throws {
    let accountId = UUID()
    let account = Account(
      id: accountId, name: "Revolut", type: .bank,
      instrument: .defaultTestInstrument)
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(accounts: [account], in: database)

    let tx1 = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: .AUD,
          quantity: dec("1000.00"),
          type: .openingBalance
        )
      ]
    )
    let tx2 = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: .USD,
          quantity: dec("500.00"),
          type: .openingBalance
        )
      ]
    )
    TestBackend.seed(transactions: [tx1, tx2], in: database)

    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument
    )
    await expectEventually("both AUD and USD positions settle") {
      let positions = store.positions(for: accountId)
      return positions.count == 2
        && positions.contains(where: { $0.instrument == .AUD && $0.quantity == dec("1000.00") })
        && positions.contains(where: { $0.instrument == .USD && $0.quantity == dec("500.00") })
    }
  }

  @Test
  func convertedTotalSumsAllPositionsInProfileCurrency() async throws {
    let accountId = UUID()
    let account = Account(
      id: accountId, name: "Revolut", type: .bank,
      instrument: .defaultTestInstrument)
    // Cache cap routes today's request to yesterday's row — see
    // `Shared/PriceCacheCap.swift`. Seed both keys with the same value
    // so the assertion is independent of UTC midnight crossings.
    let todayString = Date().iso8601DateOnlyString
    let yesterdayString = Date().addingTimeInterval(-86400).iso8601DateOnlyString
    let rates: [String: [String: Decimal]] = [
      todayString: ["AUD": dec("1.5385")],
      yesterdayString: ["AUD": dec("1.5385")],
    ]
    let (backend, database) = try TestBackend.create(exchangeRates: rates)
    TestBackend.seed(accounts: [account], in: database)

    let tx1 = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: .AUD,
          quantity: dec("1000.00"),
          type: .openingBalance
        )
      ]
    )
    let tx2 = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: .USD,
          quantity: dec("500.00"),
          type: .openingBalance
        )
      ]
    )
    TestBackend.seed(transactions: [tx1, tx2], in: database)

    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument
    )
    // 1000 AUD + 500 USD converted to AUD (500 * 1.5385 = 769.25)
    let expectedUsdInAud = dec("500.00") * dec("1.5385")
    let expected = dec("1000.00") + expectedUsdInAud
    await expectEventually("converted total settles to AUD sum") {
      let total = try? await store.computeConvertedCurrentTotal(in: .AUD)
      return total?.quantity == expected && total?.instrument == .AUD
    }
  }

  @Test
  func positionsForUnknownAccountReturnsEmpty() async throws {
    let (backend, _) = try TestBackend.create()
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument
    )
    try await store.waitForFirstEmission()
    #expect(store.positions(for: UUID()).isEmpty)
  }
}
