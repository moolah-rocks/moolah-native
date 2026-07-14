import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("TransactionRepository observation contract")
struct TransactionRepoObservationContractTests {

  // MARK: - observeAll(filter:)

  @Test("observeAll initial emission reflects current DB state")
  func observeAllInitialEmission() async throws {
    let (backend, _) = try TestBackend.create()
    var iterator = backend.transactions.observeAll(filter: TransactionFilter())
      .makeAsyncIterator()
    let initial = await iterator.next()
    #expect(initial?.isEmpty == true)
  }

  @Test("observeAll emits when a matching transaction is created")
  func observeAllEmitsOnRelevantWrite() async throws {
    let (backend, _) = try TestBackend.create()
    let account = try await makeAccount(backend: backend, name: "Checking")
    let filter = TransactionFilter(accountId: account.id)

    var iterator = backend.transactions.observeAll(filter: filter).makeAsyncIterator()
    _ = await iterator.next()  // initial empty

    _ = try await backend.transactions.create(
      makeTransaction(amount: 100, accountId: account.id, payee: "Coffee"))

    let afterCreate = await iterator.next()
    #expect(afterCreate?.count == 1)
    #expect(afterCreate?.first?.payee == "Coffee")
  }

  @Test("observeAll suppresses duplicates from irrelevant writes via removeDuplicates")
  func observeAllNoEmissionOnIrrelevantWrite() async throws {
    let (backend, _) = try TestBackend.create()
    let trackedAccount = try await makeAccount(backend: backend, name: "Tracked")
    let otherAccount = try await makeAccount(backend: backend, name: "Other")
    let filter = TransactionFilter(accountId: trackedAccount.id)

    var iterator = backend.transactions.observeAll(filter: filter).makeAsyncIterator()
    _ = await iterator.next()  // initial empty for `trackedAccount`

    // Region tracking re-evaluates the closure on any `transaction` /
    // `transaction_leg` write, but the projection it returns for
    // `trackedAccount` is unchanged → `removeDuplicates()` suppresses
    // the duplicate. We poll for ~200ms; a duplicate emission would
    // arrive within that window.
    _ = try await backend.transactions.create(
      makeTransaction(amount: 50, accountId: otherAccount.id, payee: "Unrelated"))

    let receivedBox = LockedBox<Bool>(false)
    let pollTask = Task<Void, Never> { [receivedBox] in
      var localIterator = iterator
      if await localIterator.next() != nil {
        receivedBox.set(true)
      }
    }
    try? await Task.sleep(for: .milliseconds(200))
    pollTask.cancel()
    _ = await pollTask.value
    #expect(
      receivedBox.get() == false,
      "removeDuplicates failed: an irrelevant write produced a re-emission")
  }

  // MARK: - observe(filter:page:pageSize:)

  @Test("observe initial emission reflects current state with pagination")
  func observePagedInitialEmission() async throws {
    let (backend, _) = try TestBackend.create()
    let account = try await makeAccount(backend: backend, name: "Checking")
    // Seed three transactions; page 0 with size 2 should show two of them.
    for index in 0..<3 {
      _ = try await backend.transactions.create(
        makeTransaction(
          amount: 10 + index,
          accountId: account.id,
          payee: "Seed \(index)",
          date: Date().addingTimeInterval(TimeInterval(-index * 60))))
    }

    var iterator = backend.transactions.observe(
      filter: TransactionFilter(accountId: account.id),
      page: 0,
      pageSize: 2
    ).makeAsyncIterator()

    let initial = await iterator.next()
    #expect(initial?.transactions.count == 2)
    #expect(initial?.totalCount == 3)
  }

  @Test("observe re-emits when a write lands within the page")
  func observePagedEmitsOnInPageWrite() async throws {
    let (backend, _) = try TestBackend.create()
    let account = try await makeAccount(backend: backend, name: "Checking")
    let filter = TransactionFilter(accountId: account.id)

    var iterator = backend.transactions.observe(
      filter: filter, page: 0, pageSize: 10
    ).makeAsyncIterator()
    _ = await iterator.next()  // initial empty

    _ = try await backend.transactions.create(
      makeTransaction(amount: 75, accountId: account.id, payee: "InPage"))

    let afterCreate = await iterator.next()
    #expect(afterCreate?.transactions.count == 1)
    #expect(afterCreate?.transactions.first?.payee == "InPage")
    #expect(afterCreate?.totalCount == 1)
  }

  @Test("tax invalidation emits when an older off-page transaction changes")
  func taxInvalidationEmitsForOffPageChange() async throws {
    let (backend, _) = try TestBackend.create()
    let account = try await makeAccount(backend: backend, name: "Checking")
    let filter = TransactionFilter(accountId: account.id)
    let baseDate = Date(timeIntervalSinceReferenceDate: 10_000)
    var oldest = try await backend.transactions.create(
      makeTransaction(
        amount: 10,
        accountId: account.id,
        payee: "Oldest",
        date: baseDate))
    _ = try await backend.transactions.create(
      makeTransaction(
        amount: 20,
        accountId: account.id,
        payee: "Middle",
        date: baseDate.addingTimeInterval(60)))
    _ = try await backend.transactions.create(
      makeTransaction(
        amount: 30,
        accountId: account.id,
        payee: "Newest",
        date: baseDate.addingTimeInterval(120)))

    var pageIterator = backend.transactions.observe(
      filter: filter, page: 0, pageSize: 1
    ).makeAsyncIterator()
    let initialPage = await pageIterator.next()
    #expect(initialPage?.transactions.first?.payee == "Newest")

    var invalidationIterator = backend.transactions.observeTaxRelevantChanges(
      filter: filter
    ).makeAsyncIterator()
    _ = await invalidationIterator.next()

    oldest.payee = "Edited off page"
    _ = try await backend.transactions.update(oldest)

    _ = await invalidationIterator.next()
    let unchangedPage = try await backend.transactions.fetch(filter: filter, page: 0, pageSize: 1)
    #expect(unchangedPage.transactions.first?.payee == "Newest")
  }

  @Test("tax invalidation emits when account ownership changes")
  func taxInvalidationEmitsForAccountOwnershipChange() async throws {
    let (backend, _) = try TestBackend.create()
    var account = try await makeAccount(backend: backend, name: "Checking")
    var iterator = backend.transactions.observeTaxRelevantChanges(
      filter: TransactionFilter()
    ).makeAsyncIterator()
    _ = await iterator.next()

    account.taxOwnerIds = [UUID()]
    _ = try await backend.accounts.update(account)

    _ = await iterator.next()
  }

  @Test("tax invalidation emits when category ownership changes")
  func taxInvalidationEmitsForCategoryOwnershipChange() async throws {
    let (backend, _) = try TestBackend.create()
    var category = try await backend.categories.create(
      Category(name: "Taxable", isTaxReportable: true))
    var iterator = backend.transactions.observeTaxRelevantChanges(
      filter: TransactionFilter()
    ).makeAsyncIterator()
    _ = await iterator.next()

    category.taxOwnerIds = [UUID()]
    _ = try await backend.categories.update(category)

    _ = await iterator.next()
  }

  @Test("changing filter cancels prior subscription and starts a fresh stream")
  func changingFilterStartsFreshSubscription() async throws {
    let (backend, _) = try TestBackend.create()
    let accountA = try await makeAccount(backend: backend, name: "A")
    let accountB = try await makeAccount(backend: backend, name: "B")

    _ = try await backend.transactions.create(
      makeTransaction(amount: 1, accountId: accountA.id, payee: "Tx A"))
    _ = try await backend.transactions.create(
      makeTransaction(amount: 2, accountId: accountB.id, payee: "Tx B"))

    // First subscription scoped to A.
    var iteratorA = backend.transactions.observeAll(
      filter: TransactionFilter(accountId: accountA.id)
    ).makeAsyncIterator()
    let snapshotA = await iteratorA.next()
    #expect(snapshotA?.count == 1)
    #expect(snapshotA?.first?.payee == "Tx A")

    // The consumer cancels the prior subscription (drops the iterator) and
    // starts a new one with a different filter.
    _ = iteratorA  // drop reference
    var iteratorB = backend.transactions.observeAll(
      filter: TransactionFilter(accountId: accountB.id)
    ).makeAsyncIterator()
    let snapshotB = await iteratorB.next()
    #expect(snapshotB?.count == 1)
    #expect(snapshotB?.first?.payee == "Tx B")
  }

  // MARK: - observeErrors()

  @Test("observeErrors stays quiet on a healthy repository")
  func observeErrorsOnHealthyRepository() async throws {
    let (backend, _) = try TestBackend.create()
    let stream = backend.transactions.observeErrors()
    let pollTask = Task<(any Error)?, Never> {
      var iterator = stream.makeAsyncIterator()
      return await iterator.next()
    }
    try await Task.sleep(for: .milliseconds(100))
    pollTask.cancel()
    let surfaced = await pollTask.value
    #expect(surfaced == nil)
  }

  // MARK: - Helpers

  /// Creates an account on the supplied backend in the project's default
  /// test instrument. Mirrors the helper inlined in
  /// `AccountRepoObservationContractTests` so the contract test file
  /// stays self-contained and can run against any `TestBackend` instance.
  private func makeAccount(
    backend: CloudKitBackend, name: String
  ) async throws -> Account {
    try await backend.accounts.create(
      Account(name: name, type: .bank, instrument: .defaultTestInstrument),
      openingBalance: nil)
  }

  /// Creates a single-leg transaction in the default test instrument.
  /// `amount` is in whole units (cents would also work — the test only
  /// cares about distinct, non-zero values). `date` defaults to "now"
  /// so seeded transactions interleave on the same `date DESC, id ASC`
  /// ordering as the production fetch path.
  private func makeTransaction(
    amount: Int,
    accountId: UUID,
    payee: String,
    date: Date = Date()
  ) -> Transaction {
    Transaction(
      date: date,
      payee: payee,
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: .defaultTestInstrument,
          quantity: Decimal(amount),
          type: .income)
      ])
  }
}
