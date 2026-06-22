import Foundation
import Testing

@testable import Moolah

@Suite("TransactionStore/Autocomplete")
@MainActor
struct TransactionStoreAutocompleteTests {
  private let accountId = UUID()

  @Test
  func testFetchPayeeSuggestionsReturnsMatchingPayees() async throws {
    let transactions = [
      Transaction(
        date: try TransactionStoreTestSupport.makeDate("2024-01-01"),
        payee: "Woolworths",
        legs: [
          TransactionLeg(
            accountId: accountId,
            instrument: Instrument.defaultTestInstrument,
            quantity: Decimal(-5000) / 100,
            type: .expense
          )
        ]
      ),
      Transaction(
        date: try TransactionStoreTestSupport.makeDate("2024-01-02"),
        payee: "Woollies Market",
        legs: [
          TransactionLeg(
            accountId: accountId,
            instrument: Instrument.defaultTestInstrument,
            quantity: Decimal(-3000) / 100,
            type: .expense
          )
        ]
      ),
      Transaction(
        date: try TransactionStoreTestSupport.makeDate("2024-01-03"),
        payee: "Coles",
        legs: [
          TransactionLeg(
            accountId: accountId,
            instrument: Instrument.defaultTestInstrument,
            quantity: Decimal(-2000) / 100,
            type: .expense
          )
        ]
      ),
    ]
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(transactions: transactions, in: database)

    let suggestions = try await backend.transactions.fetchPayeeSuggestions(prefix: "Wool")
    #expect(suggestions.count == 2)
    #expect(suggestions.contains("Woolworths"))
    #expect(suggestions.contains("Woollies Market"))
    #expect(!suggestions.contains("Coles"))
  }

  @Test
  func testPayeeSuggestionsAreSortedByFrequency() async throws {
    let transactions = [
      try expenseTransaction(
        date: "2024-01-01", payee: "Woolworths", amount: Decimal(-5000) / 100),
      try expenseTransaction(
        date: "2024-01-02", payee: "Woollies Market", amount: Decimal(-3000) / 100),
      try expenseTransaction(
        date: "2024-01-03", payee: "Woolworths", amount: Decimal(-4000) / 100),
      try expenseTransaction(
        date: "2024-01-04", payee: "Woolworths", amount: Decimal(-6000) / 100),
    ]
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(transactions: transactions, in: database)

    let suggestions = try await backend.transactions.fetchPayeeSuggestions(prefix: "Wool")
    #expect(suggestions.count == 2)
    // Woolworths appears 3 times, Woollies Market once — Woolworths should be first
    #expect(suggestions[0] == "Woolworths")
    #expect(suggestions[1] == "Woollies Market")
  }

  @Test
  func testFetchTransactionForAutofillReturnsMostRecent() async throws {
    let categoryId = UUID()
    let transactions = [
      Transaction(
        date: try TransactionStoreTestSupport.makeDate("2024-01-01"),
        payee: "Woolworths",
        legs: [
          TransactionLeg(
            accountId: accountId,
            instrument: Instrument.defaultTestInstrument,
            quantity: Decimal(-3000) / 100,
            type: .expense
          )
        ]
      ),
      Transaction(
        date: try TransactionStoreTestSupport.makeDate("2024-03-01"),
        payee: "Woolworths",
        legs: [
          TransactionLeg(
            accountId: accountId,
            instrument: Instrument.defaultTestInstrument,
            quantity: Decimal(-7500) / 100,
            type: .expense,
            categoryId: categoryId
          )
        ]
      ),
    ]
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(transactions: transactions, in: database)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument
    )

    let match = await store.payeeSuggestionSource.fetchTransactionForAutofill(payee: "Woolworths")
    #expect(match != nil)
    // Most recent (newest first from server) should have the category
    #expect(match?.legs.contains(where: { $0.categoryId == categoryId }) == true)
    #expect(match?.legs.first?.quantity == Decimal(-7500) / 100)
  }

  @Test
  func testDebouncedSaveOnlyCallsLastAction() async throws {
    let (backend, _) = try TestBackend.create()
    // `.zero` short-circuits the production 300ms wait — the debounced
    // task still hops the executor, so cancellation still cancels
    // earlier saves before they run, but we don't burn wall-clock time.
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument,
      debounceInterval: .zero
    )

    var callCount = 0
    var lastValue = ""

    // Rapidly call debouncedSave 3 times — only the last should fire.
    // Discard the first two tasks; they're cancelled by the time we
    // await the third.
    store.debouncedSave {
      callCount += 1
      lastValue = "first"
    }
    store.debouncedSave {
      callCount += 1
      lastValue = "second"
    }
    let liveSave = store.debouncedSave {
      callCount += 1
      lastValue = "third"
    }

    // Await the live save's completion directly — no sleep needed.
    await liveSave.value

    #expect(callCount == 1)
    #expect(lastValue == "third")
  }

  /// Issue #48: a conversion failure while computing running balances must be
  /// surfaced on the store so the UI can render a retry path, not silently
  /// swallowed. Target is AUD; seeded transaction is in USD and the conversion
  /// service refuses the USD pair.
  @Test
  func testConversionFailureSurfacesErrorOnStore() async throws {
    let aud = Instrument.defaultTestInstrument
    let usd = Instrument.USD
    let (backend, database) = try TestBackend.create()

    let account = Account(id: accountId, name: "AUD", type: .bank, instrument: aud)
    TestBackend.seed(accounts: [account], in: database)

    let foreignTx = Transaction(
      date: try TransactionStoreTestSupport.makeDate("2024-01-05"),
      payee: "Overseas",
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: usd, quantity: Decimal(-50), type: .expense)
      ]
    )
    TestBackend.seed(transactions: [foreignTx], in: database)

    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.failingInstruments([usd.id]),
      targetInstrument: aud
    )

    await store.load(filter: TransactionFilter(accountId: accountId))

    // The row still renders so the list isn't blanked...
    #expect(store.transactions.count == 1)
    // ...but its display/balance are unavailable and the error is surfaced.
    #expect(store.transactions.first?.displayAmount == nil)
    #expect(store.transactions.first?.balance == nil)
    #expect(store.error != nil)
  }

  @Test
  func testFetchPayeeSuggestionsEmptyPrefixReturnsEmpty() async throws {
    let transactions = [
      Transaction(
        date: try TransactionStoreTestSupport.makeDate("2024-01-01"),
        payee: "Woolworths",
        legs: [
          TransactionLeg(
            accountId: accountId,
            instrument: Instrument.defaultTestInstrument,
            quantity: Decimal(-5000) / 100,
            type: .expense
          )
        ]
      )
    ]
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(transactions: transactions, in: database)

    let suggestions = try await backend.transactions.fetchPayeeSuggestions(prefix: "")
    #expect(suggestions.isEmpty)
  }

  // MARK: - Helpers

  /// Builds a single-leg expense transaction. Used to keep autocomplete test
  /// arrange blocks under the function-body-length policy by factoring out
  /// repeated fixture construction.
  private func expenseTransaction(
    date: String,
    payee: String,
    amount: Decimal
  ) throws -> Transaction {
    Transaction(
      date: try TransactionStoreTestSupport.makeDate(date),
      payee: payee,
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: amount,
          type: .expense
        )
      ]
    )
  }
}
