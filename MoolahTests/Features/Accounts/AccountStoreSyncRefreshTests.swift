import Foundation
import GRDB
import Testing

@testable import Moolah

/// Symptom-A regression coverage for the reactive `AccountStore`.
///
/// "Symptom A" is the bug that motivated the reactive-sync-refresh
/// rewrite: when CloudKit delivered a remote sync write, the sidebar
/// would not refresh until the user pulled-to-refresh. The reactive
/// `AccountStore` subscribes to `repository.observeAll()` and
/// `conversionService.observeRates()` from `init`, so any GRDB write —
/// local OR sync-driven — propagates to the sidebar without a manual
/// reload. These tests pin that contract.
@Suite("AccountStore sync refresh", .serialized)
@MainActor
struct AccountStoreSyncRefreshTests {

  @Test("remote account insert refreshes the store without manual refresh")
  func remoteAccountInsertRefreshesStore() async throws {
    let (backend, _) = try TestBackend.create()
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument
    )
    try await store.waitForFirstEmission()
    #expect(store.accounts.ordered.isEmpty)

    _ = try await backend.accounts.create(
      Account(name: "Synced", type: .bank, instrument: .defaultTestInstrument),
      openingBalance: nil
    )

    try await store.waitForNextEmission(
      matching: { $0.accounts.count == 1 },
      description: "accounts.count == 1"
    )
    #expect(store.accounts.ordered.first?.name == "Synced")
  }

  @Test(
    "rate-tick triggers convertedTotal recompute even when accounts unchanged",
    arguments: ["exchange_rate", "stock_price", "crypto_price"]
  )
  func convertedTotalRecomputesOnRateTick(table: String) async throws {
    // CRITICAL: this test MUST use the real GRDBInstrumentConversionService
    // (the one TestBackend.create() wires up — `FiatConversionService`
    // backed by the in-memory GRDB queue). Substituting `FixedConversionService`
    // or any other test double makes the test vacuous: the stub's
    // observeRates() is a no-op AsyncStream that cannot signal a
    // cache-table write, so the test would pass for the wrong reason
    // (an unrelated emission from the account observation) and would
    // not catch a regression to the empty-table region inference bug.
    let (backend, _) = try TestBackend.create()
    // The rate caches live on the registry's profile-index DB. The
    // conversion service observes that DB, so the fixture write must
    // land there.
    let cacheDatabase = backend.grdbInstruments.database
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument
    )
    try await store.waitForFirstEmission()

    // Write into the named cache table using a SQL literal helper from
    // `MoolahTests/Domain/ConversionObservationContractTests.swift`.
    // The follow-up `notifyRateCacheChange(_:)` is required for
    // WITHOUT ROWID tables — without it the SQLite update hook never
    // fires and the observation hangs (see
    // `Backends/GRDB/Observation/RateCacheTable.swift`).
    try await cacheDatabase.write { connection in
      switch table {
      case "exchange_rate":
        try connection.execute(literal: insertExchangeRateFixture())
        try connection.notifyRateCacheChange(.exchangeRate)
      case "stock_price":
        try connection.execute(literal: insertStockPriceFixture())
        try connection.notifyRateCacheChange(.stockPrice)
      case "crypto_price":
        try connection.execute(literal: insertCryptoPriceFixture())
        try connection.notifyRateCacheChange(.cryptoPrice)
      default:
        Issue.record("unknown table \(table)")
      }
    }

    try await store.waitForNextEmission(
      matching: { _ in true },
      description: "any emission post-rate-write to \(table)",
      timeout: .seconds(2)
    )
  }

  @Test("stopObserving cancels the observation task")
  func stopObservingCancelsObservationTask() async throws {
    let (backend, _) = try TestBackend.create()
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument
    )
    try await store.waitForFirstEmission()
    // Drain any ticks buffered between init and the first
    // `waitForFirstEmission` so the post-cancel assertion only sees
    // ticks that arrive AFTER the backend write.
    await store.drainPendingEmissions()
    store.stopObserving()
    // `stopObserving()` returns the moment `Task.cancel()` is issued;
    // the observation task's `for await` loops only notice cancellation
    // on the next stream check. Without awaiting termination, an
    // in-flight emission triggered by the following `create(...)` can
    // race the cancel under CI load and a 200 ms `didEmitWithin`
    // window then flakes.
    await store.awaitObservationTermination()

    _ = try await backend.accounts.create(
      Account(name: "After cancel", type: .bank, instrument: .defaultTestInstrument),
      openingBalance: nil
    )
    let didEmit = await store.didEmitWithin(timeout: .milliseconds(200))
    #expect(didEmit == false)
  }

  @Test("mutation via TransactionStore does not double-apply positions to AccountStore")
  func mutationViaTransactionStoreDoesNotDoubleApply() async throws {
    // Regression test for the accountStore.applyDelta fan-out race:
    // 1. transactionStore.create writes a transaction + leg to GRDB.
    // 2. The GRDB write fires the observation → AccountStore.apply(accounts: fresh)
    //    runs on MainActor with the authoritative post-write positions.
    // 3. If applyDelta were still called from applyBalanceDeltas, the delta
    //    would be applied ON TOP OF already-fresh state, doubling the position.
    //    This test would see quantity == -100 instead of -50 in that case.
    let accountId = UUID()
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        (
          account: Account(
            id: accountId, name: "Checking", type: .bank,
            instrument: .defaultTestInstrument),
          openingBalance: .zero(instrument: .defaultTestInstrument)
        )
      ],
      in: database)

    let accountStore = AccountStore(
      repository: backend.accounts,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )
    // Wait for the seeded account to be visible before mutating.
    try await accountStore.waitForNextEmission(
      matching: { $0.accounts.count == 1 },
      description: "seeded account visible"
    )

    let transactionStore = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )
    await transactionStore.load(filter: TransactionFilter(accountId: accountId))

    let transaction = Transaction(
      date: Date(),
      payee: "Coffee",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: .defaultTestInstrument,
          quantity: Decimal(-5000) / 100,  // -50.00
          type: .expense
        )
      ]
    )
    _ = await transactionStore.create(transaction)

    // Wait for the reactive observation to deliver the post-write state.
    // The predicate checks that positions are non-empty (the -50 leg landed).
    try await accountStore.waitForNextEmission(
      matching: { $0.accounts.by(id: accountId)?.positions.isEmpty == false },
      description: "account positions updated after transaction create"
    )

    // Read SYNCHRONOUSLY — no await. If applyDelta were still fanned out
    // from TransactionStore, the position would be -100 (observation applied
    // -50, then applyDelta applied another -50 on top). Under the reactive-only
    // design, observation is the single source of truth and the value is -50.
    let positions = accountStore.accounts.by(id: accountId)?.positions ?? []
    let qty = positions.first(where: { $0.instrument == .defaultTestInstrument })?.quantity
    #expect(qty == Decimal(-5000) / 100)
  }

  @Test("AccountStore reflects InvestmentValue writes via observeAll")
  func investmentValueWriteReachesAccountStore() async throws {
    let (backend, _) = try TestBackend.create()
    let investmentAccount = try await backend.accounts.create(
      Account(
        name: "Brokerage",
        type: .investment,
        instrument: .defaultTestInstrument,
        valuationMode: .recordedValue
      ),
      openingBalance: nil
    )
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument,
      investmentRepository: backend.investments
    )
    try await store.waitForFirstEmission()

    // Write directly to investment_value via the GRDB layer (simulating
    // a remote sync update).
    try await backend.investments.setValue(
      accountId: investmentAccount.id,
      date: .now,
      value: InstrumentAmount(quantity: 12345, instrument: .defaultTestInstrument)
    )

    try await store.waitForNextEmission(
      matching: { $0.convertedBalances[investmentAccount.id]?.quantity == 12345 },
      description: "investment value reaches account store",
      timeout: .seconds(2)
    )
  }

  @Test("stale instrument-registry refresh does not clobber a fresher accounts snapshot")
  func staleRegistryRefreshIsDropped() async throws {
    // Regression for the `AutomationServiceAccountTests` flake: the
    // instrument-registry refresh path runs `repository.fetchAll()`
    // unordered with respect to `observeAll()`. A `fetchAll()` that read
    // the database before a concurrent write committed returns a stale
    // (here: empty) row set; without the generation guard, applying it
    // after a fresher authoritative snapshot would clobber `accounts`
    // back to the pre-write state. The guard must drop the stale apply.
    let (backend, _) = try TestBackend.create()
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )
    let first = try await backend.accounts.create(
      Account(name: "First", type: .bank, instrument: .defaultTestInstrument),
      openingBalance: nil
    )
    try await store.waitForNextEmission(
      matching: { $0.accounts.by(id: first.id) != nil },
      description: "first account visible"
    )

    // The registry path captures the generation BEFORE its fetch.
    let observedGeneration = store.snapshotGeneration

    // An authoritative `observeAll()` snapshot lands while the (simulated)
    // stale fetch is still in flight, bumping the generation.
    let second = try await backend.accounts.create(
      Account(name: "Second", type: .bank, instrument: .defaultTestInstrument),
      openingBalance: nil
    )
    try await store.waitForNextEmission(
      matching: { $0.accounts.by(id: second.id) != nil },
      description: "second account visible"
    )

    // The stale, empty refetch resolves last. It must be dropped, not
    // applied — both accounts survive.
    await store.applyInstrumentRegistryRefresh([], observedGeneration: observedGeneration)
    #expect(store.accounts.by(id: first.id) != nil)
    #expect(store.accounts.by(id: second.id) != nil)
  }

  @Test("up-to-date instrument-registry refresh applies")
  func currentRegistryRefreshApplies() async throws {
    // Companion to `staleRegistryRefreshIsDropped`: when no authoritative
    // snapshot has landed since the fetch was issued, the refresh applies
    // (this is the live-instrument-metadata refresh the path exists for).
    let (backend, _) = try TestBackend.create()
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )
    let account = try await backend.accounts.create(
      Account(name: "Original", type: .bank, instrument: .defaultTestInstrument),
      openingBalance: nil
    )
    try await store.waitForNextEmission(
      matching: { $0.accounts.by(id: account.id) != nil },
      description: "account visible"
    )

    // Capture the current generation and apply a refresh tagged with it —
    // simulating a fetch that observed the latest snapshot. A renamed copy
    // proves the refresh was applied rather than dropped.
    let observedGeneration = store.snapshotGeneration
    var renamed = account
    renamed.name = "Renamed"
    await store.applyInstrumentRegistryRefresh([renamed], observedGeneration: observedGeneration)
    #expect(store.accounts.by(id: account.id)?.name == "Renamed")
  }

  @Test("GRDB wipes during sign-out reach the store before stopObserving cancels it")
  func signOutTeardownOrdering() async throws {
    let (backend, database) = try TestBackend.create()
    _ = try await backend.accounts.create(
      Account(name: "WillBeWiped", type: .bank, instrument: .defaultTestInstrument),
      openingBalance: nil
    )
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument
    )
    try await store.waitForNextEmission(
      matching: { $0.accounts.count == 1 },
      description: "store sees seeded account"
    )

    // Simulate the sign-out path: GRDB wipes happen first, then
    // `stopObserving()` cancels the observation. The wipe-emission
    // must reach the store BEFORE cancellation, otherwise the user
    // would see the last-known-populated state frozen on screen until
    // they switched profiles or relaunched.
    try await database.write { connection in
      try connection.execute(sql: "DELETE FROM account")
    }
    try await store.waitForNextEmission(
      matching: { $0.accounts.ordered.isEmpty },
      description: "wipe propagated to store before cancellation",
      timeout: .seconds(2)
    )
    store.stopObserving()
    #expect(store.accounts.ordered.isEmpty)
  }
}
