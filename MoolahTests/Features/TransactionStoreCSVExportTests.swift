import Foundation
import Testing

@testable import Moolah

@Suite("TransactionStore CSV export")
@MainActor
struct TransactionStoreCSVExportTests {
  @Test("exports all filtered transactions beyond the loaded page")
  func exportsBeyondLoadedPage() async throws {
    let accountId = UUID()
    let transactions = try TransactionStoreTestSupport.seedTransactions(
      count: 4,
      accountId: accountId)
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(transactions: transactions, in: database)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument,
      pageSize: 1)
    let context = TransactionCSVExportContext(
      filter: TransactionFilter(accountId: accountId),
      searchText: "",
      includesSpam: true,
      spamInstruments: [],
      timeZone: .utc,
      accounts: Accounts(from: []),
      categories: Categories(from: []),
      earmarks: Earmarks(from: []))

    await store.load(filter: context.filter)
    await store.csvExportStore.export(context: context)

    #expect(store.transactions.count == 1)
    let rows = try CSVTokenizer.parse(Data(store.csvExportStore.document.csv.utf8))
    #expect(rows.count == 5)
    #expect(store.csvExportStore.errorMessage == nil)
    #expect(store.csvExportStore.isPresented)
  }

  @Test("clears an earlier error when a later export succeeds")
  func clearsErrorAfterRecovery() async throws {
    let transaction = Transaction(
      date: Date(timeIntervalSince1970: 0),
      payee: "Recovered export",
      legs: [
        TransactionLeg(
          accountId: nil,
          instrument: .defaultTestInstrument,
          quantity: -1,
          type: .expense)
      ])
    let fetcher = FailOnceCSVExportFetcher(transactions: [transaction])
    let repository = FailingTransactionRepository { filter in
      try await fetcher.fetch(filter: filter)
    }
    let exportStore = TransactionCSVExportStore(repository: repository)
    let context = TransactionCSVExportContext(
      filter: TransactionFilter(),
      searchText: "",
      includesSpam: true,
      spamInstruments: [],
      timeZone: .utc,
      accounts: Accounts(from: []),
      categories: Categories(from: []),
      earmarks: Earmarks(from: []))

    await exportStore.export(context: context)

    #expect(exportStore.errorMessage != nil)
    #expect(!exportStore.isPresented)

    await exportStore.export(context: context)

    #expect(exportStore.errorMessage == nil)
    #expect(exportStore.isPresented)
    #expect(exportStore.document.csv.contains("Recovered export"))
  }
}

private actor FailOnceCSVExportFetcher {
  private let transactions: [Transaction]
  private var hasFailed = false

  init(transactions: [Transaction]) {
    self.transactions = transactions
  }

  func fetch(filter _: TransactionFilter) throws -> [Transaction] {
    if !hasFailed {
      hasFailed = true
      throw BackendError.networkUnavailable
    }
    return transactions
  }
}
