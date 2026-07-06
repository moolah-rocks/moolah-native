import Foundation
import Testing

@testable import Moolah

/// Sentinel raised by `CountingTransactionRepository` when configured to fail
/// the key-event query — stands in for a genuine build failure (query throws /
/// conversion batch throws) that must propagate, never degrade to `.empty`.
private struct CostBasisQueryFailure: Error {}

/// Counting `TransactionRepository` double: only `fetchCostBasisEventLegs` is
/// exercised (it records the call count and optionally throws); every other
/// requirement traps, mirroring `CancellablePagingTransactionRepository`.
private actor CountingTransactionRepository: TransactionRepository {
  private var legRows: [CostBasisEventLegRow]
  private var shouldThrow: Bool
  private(set) var fetchCount = 0
  /// Optional gates that block ONLY the first `fetchCostBasisEventLegs` call
  /// so a test can hold a build in flight, join a second caller, and fire
  /// `invalidate()` before the build completes.
  private let firstFetchStarted: AsyncGate?
  private let releaseFirstFetch: AsyncGate?

  init(
    legRows: [CostBasisEventLegRow],
    shouldThrow: Bool = false,
    firstFetchStarted: AsyncGate? = nil,
    releaseFirstFetch: AsyncGate? = nil
  ) {
    self.legRows = legRows
    self.shouldThrow = shouldThrow
    self.firstFetchStarted = firstFetchStarted
    self.releaseFirstFetch = releaseFirstFetch
  }

  func setLegRows(_ rows: [CostBasisEventLegRow]) { legRows = rows }
  func setShouldThrow(_ value: Bool) { shouldThrow = value }

  func fetchCostBasisEventLegs() async throws -> [CostBasisEventLegRow] {
    fetchCount += 1
    // Snapshot the rows at call time so the (superseded) first build sees the
    // pre-edit data even if the test mutates `legRows` while it is gated.
    let rows = legRows
    if fetchCount == 1, let firstFetchStarted, let releaseFirstFetch {
      await firstFetchStarted.open()
      await releaseFirstFetch.wait()
    }
    if shouldThrow { throw CostBasisQueryFailure() }
    return rows
  }

  nonisolated func observe(
    filter: TransactionFilter, page: Int, pageSize: Int
  ) -> AsyncStream<TransactionPage> {
    AsyncStream { $0.finish() }
  }
  nonisolated func observeAll(filter: TransactionFilter) -> AsyncStream<[Transaction]> {
    AsyncStream { $0.finish() }
  }
  nonisolated func observeErrors() -> AsyncStream<any Error> {
    AsyncStream { $0.finish() }
  }
  // Remaining `TransactionRepository` requirements are unexercised by this
  // suite — trivial returns (mirroring `CancellablePagingTransactionRepository`)
  // rather than `fatalError`, which SwiftLint's `unavailable_function` rejects.
  func fetch(filter: TransactionFilter, page: Int, pageSize: Int) async throws -> TransactionPage {
    TransactionPage(
      transactions: [], targetInstrument: .defaultTestInstrument, priorBalance: nil,
      totalCount: nil)
  }
  func fetchAll(filter: TransactionFilter) async throws -> [Transaction] { [] }
  func create(_ transaction: Transaction) async throws -> Transaction { transaction }
  func createMany(_ transactions: [Transaction]) async throws -> [Transaction] { transactions }
  func update(_ transaction: Transaction) async throws -> Transaction { transaction }
  func delete(id: UUID) async throws {}
  func replace(deletingIds: [UUID], creating: [Transaction]) async throws -> [Transaction] {
    creating
  }
  func fetchPayeeSuggestions(
    prefix: String, excludingTransactionId: UUID?
  ) async throws -> [String] { [] }
  func legs(matchingExternalId externalId: String) async throws -> [TransactionLeg] { [] }
  func transactions(touchingExternalIds externalIds: Set<String>) async throws -> [Transaction] {
    []
  }
  func legExists(accountId: UUID, externalId: String) async throws -> Bool { false }
  func distinctLegInstrumentIds() async throws -> Set<String> { [] }
  func countNeedsReview() async throws -> Int { 0 }
}

@Suite("HoldingsCostLedgerStore")
@MainActor
struct HoldingsCostLedgerStoreTests {
  private let aud = Instrument.AUD
  private let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
  private let account = UUID()
  private let day = Date(timeIntervalSince1970: 1_700_000_000)

  private func row() -> CostBasisEventLegRow {
    CostBasisEventLegRow(
      transactionId: UUID(), date: day, accountId: account, instrument: eth,
      quantity: 1, type: .income, sortOrder: 0)
  }

  @Test
  func ledger_builtOnce_reusedAcrossCallsWithoutChange() async throws {
    let repo = CountingTransactionRepository(legRows: [row()])
    let store = HoldingsCostLedgerStore(
      transactionRepository: repo,
      conversionService: FakeConversionService.fixedRates([eth.id: 4_000]),
      referenceCurrency: aud)
    let first = try await store.ledger()
    let second = try await store.ledger()
    #expect(await repo.fetchCount == 1)  // one build served both calls
    #expect(first == second)
  }

  @Test
  func ledger_isEmpty_whileMigrating() async throws {
    let repo = CountingTransactionRepository(legRows: [row()])
    let store = HoldingsCostLedgerStore(
      transactionRepository: repo,
      conversionService: FakeConversionService.fixedRates([eth.id: 4_000]),
      referenceCurrency: aud, isMigrating: { true })
    #expect(try await store.ledger() == .empty)
    #expect(await repo.fetchCount == 0)  // never queried while gated
  }

  /// A GENUINE build failure (the key-event query throws) must PROPAGATE —
  /// never be swallowed into `.empty`. `.empty`'s `remainingInvested` returns
  /// 0 (not nil), so degrading a real failure to `.empty` would silently
  /// render "0 invested" instead of "unavailable" (Rule 11). The migration
  /// gate is the ONLY sanctioned `.empty` path, and it does so WITHOUT
  /// querying (see `ledger_isEmpty_whileMigrating`).
  @Test
  func ledger_genuineBuildFailure_propagates_notEmpty() async throws {
    let repo = CountingTransactionRepository(legRows: [row()], shouldThrow: true)
    let store = HoldingsCostLedgerStore(
      transactionRepository: repo,
      conversionService: FakeConversionService.fixedRates([eth.id: 4_000]),
      referenceCurrency: aud)
    await #expect(throws: CostBasisQueryFailure.self) {
      _ = try await store.ledger()
    }
    #expect(store.hasCachedLedger == false)  // a failure is never cached
    #expect(await repo.fetchCount == 1)  // it did query (unlike the migration gate)

    // A later call retries (the failure was not stuck behind the in-flight
    // handle) and succeeds once the fault clears.
    await repo.setShouldThrow(false)
    let recovered = try await store.ledger()
    #expect(recovered.remainingInvested(accountIds: [account], onOrBefore: day) == 4_000)
  }

  /// (a) manual edit/create/delete — arrives on the `observeAll()` seam (the
  /// app's own GRDB connection). The provider fully rebuilds.
  @Test
  func ledger_rebuilds_afterTransactionEdit() async throws {
    let (changes, continuation) = AsyncStream<[Transaction]>.makeStream()
    let repo = CountingTransactionRepository(legRows: [row()])
    let store = HoldingsCostLedgerStore(
      transactionRepository: repo,
      conversionService: FakeConversionService.fixedRates([eth.id: 4_000]),
      referenceCurrency: aud, transactionChanges: changes)
    _ = try await store.ledger()
    #expect(await repo.fetchCount == 1)

    await repo.setLegRows([row(), row()])  // a transaction mutated
    continuation.yield([])  // observeAll() fires
    for _ in 0..<1_000 where store.hasCachedLedger { await Task.yield() }
    #expect(store.hasCachedLedger == false)  // invalidated (full rebuild pending)

    _ = try await store.ledger()
    #expect(await repo.fetchCount == 2)  // rebuilt from scratch, not stale
  }

  /// (b) sync/import write through a *separate* GRDB connection —
  /// `observeAll()` never fires for it (`AccountGroupStore.swift:35-42`); the
  /// import backstop is the instrument-registry `observeChanges()` seam an
  /// import always pings. The provider must rebuild off *that* seam too.
  @Test
  func ledger_rebuilds_afterSeparateConnectionImport() async throws {
    let (instrumentChanges, continuation) = AsyncStream<Void>.makeStream()
    let repo = CountingTransactionRepository(legRows: [row()])
    let store = HoldingsCostLedgerStore(
      transactionRepository: repo,
      conversionService: FakeConversionService.fixedRates([eth.id: 4_000]),
      referenceCurrency: aud, instrumentChanges: instrumentChanges)
    _ = try await store.ledger()
    #expect(await repo.fetchCount == 1)

    await repo.setLegRows([row(), row()])  // import committed on its own connection
    continuation.yield(())  // observeChanges() (import backstop) fires
    for _ in 0..<1_000 where store.hasCachedLedger { await Task.yield() }
    #expect(store.hasCachedLedger == false)  // invalidated

    _ = try await store.ledger()
    #expect(await repo.fetchCount == 2)  // rebuilt — import reflected, not stale
  }

  /// A SECOND caller that joins an in-flight build (via the shared
  /// `buildTask`) must ALSO honour a mid-flight `invalidate()`: it captures
  /// and rechecks the generation around its await, so it retries rather than
  /// publishing the superseded (pre-edit) snapshot — the #1209 clobber class.
  @Test
  func ledger_joinerHonoursMidFlightSupersession() async throws {
    let started = AsyncGate()
    let release = AsyncGate()
    // Pre-edit data: 1 ETH income → invested 4000.
    let repo = CountingTransactionRepository(
      legRows: [row()], firstFetchStarted: started, releaseFirstFetch: release)
    let store = HoldingsCostLedgerStore(
      transactionRepository: repo,
      conversionService: FakeConversionService.fixedRates([eth.id: 4_000]),
      referenceCurrency: aud)

    // Originator A starts the build; it blocks inside the gated first fetch
    // (with `buildTask` already set).
    let taskA = Task { try await store.ledger() }
    await started.wait()

    // Joiner B attaches to the SAME in-flight `buildTask`.
    let taskB = Task { try await store.ledger() }
    for _ in 0..<10 { await Task.yield() }  // let B reach `await buildTask.value`

    // A transaction/import change supersedes the in-flight build and swaps in
    // post-edit data: 2 ETH income → invested 8000.
    await repo.setLegRows([row(), row()])
    store.invalidate()

    // Release the now-superseded first build.
    await release.open()

    let ledgerA = try await taskA.value
    let ledgerB = try await taskB.value

    // Both the originator AND the joiner see the POST-invalidate ledger —
    // never the pre-edit 4000 snapshot.
    #expect(ledgerA.remainingInvested(accountIds: [account], onOrBefore: day) == 8_000)
    #expect(ledgerB.remainingInvested(accountIds: [account], onOrBefore: day) == 8_000)
    #expect(await repo.fetchCount == 2)  // one superseded build + one fresh rebuild
  }
}
