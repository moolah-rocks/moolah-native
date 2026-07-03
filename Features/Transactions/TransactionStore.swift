import Foundation
import OSLog
import Observation

@Observable
@MainActor
final class TransactionStore {
  // MARK: - Stored properties

  /// View-visible list, spam-filtered from `unfilteredTransactions`.
  /// Written only via `setTransactions(_:)` or `publishFilteredTransactions()`.
  /// See `plans/2026-05-20-hide-spam-transactions-design.md`.
  private(set) var transactions: [TransactionWithBalance] = []
  // private(set): `+SpamFilter.swift` only reads this via the property accessor
  // in `publishFilteredTransactions`; `setTransactions(_:)` in this file is
  // the sole writer.
  private(set) var unfilteredTransactions: [TransactionWithBalance] = []
  /// When `true`, all-legs-spam transactions appear in `transactions`.
  /// Bound to `@AppStorage("showSpamTransactions")` by sidebar / list views.
  var showSpam: Bool = false {
    didSet {
      guard oldValue != showSpam else { return }
      publishFilteredTransactions()
    }
  }
  /// Instruments flagged as spam. Written via `setSpamInstruments(_:)`
  /// in `+SpamFilter.swift`; drives `publishFilteredTransactions()`.
  private(set) var spamInstruments: Set<Instrument> = []
  /// True until the active subscription's first emission settles.
  /// Distinguishes "still loading" from "loaded but empty" for the
  /// empty-state overlay and the load-more footer. Observed; never
  /// directly mutated by views.
  private(set) var isLoading = false
  private(set) var hasMore = true
  private(set) var error: Error?
  private(set) var loadedCount = 0
  private(set) var totalCount: Int?
  /// True while a `payScheduledTransaction` call is in flight. Views observe
  /// this to show a progress indicator on the Pay button.
  private(set) var isPayingScheduled = false

  // internal (not `private`) so the `+Observation` and `+Mutations`
  // extension files can reach the repository for the apply pipeline and
  // pass-through writes.
  let repository: TransactionRepository
  /// Owns the payee-autocomplete debounce/fetch state and the autofill
  /// lookup. Exposed directly so views bind through the dedicated type
  /// rather than a mirrored surface on `TransactionStore`.
  let payeeSuggestionSource: PayeeSuggestionSource
  // internal so the `+Observation` extension can prefetch rates for the
  // running-balance recompute on each emission.
  let conversionService: any InstrumentConversionService
  /// The store's default target instrument (profile currency). Used for views
  /// that don't narrow to a single account — scheduled, upcoming, analysis.
  private(set) var targetInstrument: Instrument
  /// The instrument used for the currently-loaded view.
  /// Account-scoped views display balances in the account's own currency so
  /// native legs don't require conversion. The repository reports the
  /// account's instrument via `TransactionPage.targetInstrument`, and the
  /// store aligns to it on every emission of the active subscription.
  private(set) var currentTargetInstrument: Instrument
  // internal so `+Observation` can read the page-size constant when
  // computing the windowed pageSize for the active subscription.
  let pageSize: Int
  // internal so `+Observation` and `+Mutations` log under the same
  // subsystem/category.
  let logger = Logger(subsystem: "com.moolah.app", category: "TransactionStore")
  /// Filter that drives the active subscription. Exposed so views sharing
  /// the store (Analysis, Upcoming) can ignore stale contents from a prior
  /// subscription until their own `.task(id: filter)` re-subscribes. When
  /// no subscription is active yet, this is the default empty filter.
  private(set) var currentFilter = TransactionFilter()
  /// Number of pages currently surfaced by the active subscription.
  /// Starts at 1; `loadMore()` increments it and signals the observe
  /// loop to resubscribe with `pageSize * pageWindow` rows. internal so
  /// `+Observation` can read it; written only here and `loadMore()`.
  var pageWindow: Int = 1

  /// Snapshot returned from `repository.fetch(...)` for the active filter,
  /// including `priorBalance` and `targetInstrument`. Stored so the
  /// running-balance recompute path can re-apply rates without re-fetching
  /// when only the rate cache ticks. internal so `+Observation` can mutate.
  var lastSnapshotPage: TransactionPage?

  /// Continuation for the "restart current subscription" channel.
  /// `loadMore()` and refresh paths yield `()`; the observe loop reacts
  /// by tearing down the current `for await` and resubscribing with the
  /// new window. internal so `+Observation` can yield from the restart
  /// path. Nil when no subscription is active.
  var subscriptionRestartContinuation: AsyncStream<Void>.Continuation?

  /// Awaiters parked on `load(filter:)` calls — woken by the next
  /// `applySnapshot(...)`. Multiple concurrent `load(filter:)` calls
  /// each register their own continuation; all are resumed by the
  /// same emission. internal so `+Observation` can park / resume.
  var pendingLoadAwaiters: [CheckedContinuation<Void, Never>] = []

  /// Generation counter bumped every time `observe(filter:)` is called or
  /// the subscription window changes. Stale fetches and stale conversions
  /// check it before mutating state so a superseded operation can early-
  /// return. internal so `+Observation` and `+Mutations` can read it.
  var loadGeneration: Int = 0

  /// Monotonic counter bumped whenever `lastSnapshotPage` is (re)assigned
  /// (distinct from `loadGeneration`, which isn't bumped on a same-filter
  /// emission). `recomputeBalances` captures it before suspending in the
  /// conversion layer and drops its publish if a fresher snapshot landed
  /// meanwhile, so a stale rate-tick recompute can't clobber fresher rows
  /// (#1209). Only `bumpSnapshotGeneration()` writes it; no view reads it.
  @ObservationIgnored private(set) var snapshotGeneration: UInt64 = 0

  /// The single increment path for `snapshotGeneration`. Internal so the
  /// `+Observation` extension can bump it past the property's `private(set)`.
  func bumpSnapshotGeneration() { snapshotGeneration &+= 1 }

  /// Test-only emission tick stream. Yields `()` after every `apply(page:)`
  /// in `+Observation` and after every recompute in
  /// `recomputeBalances()`. Tests use the `TestableStoreObservation`
  /// helpers in `MoolahTests/Support/TestableStoreObservation.swift` to
  /// await emissions deterministically. `internal` access is intentional;
  /// `@testable import Moolah` exposes it to the test target.
  ///
  /// **Spam-filter note:** the `publishFilteredTransactions()` re-publish
  /// path does NOT yield a tick — ticks are emitted only for DB-driven
  /// emissions (`applySnapshot`) and rate recomputes. Tests that toggle
  /// `showSpam` or call `setSpamInstruments(_:)` must assert against
  /// `store.transactions` synchronously (the property is updated
  /// synchronously by `publishFilteredTransactions()`) rather than
  /// awaiting a tick.
  let testObservationTickStream: AsyncStream<Void>
  // internal so `+Observation` and `+Mutations` can yield ticks after
  // mutating state.
  let testObservationTickContinuation: AsyncStream<Void>.Continuation

  /// The single observation `Task` subscribing to
  /// `conversionService.observeRates()` and `…observeErrors()`. Spawned
  /// from `init`; torn down by `stopObserving()`.
  private var rateObservationTask: Task<Void, Never>?

  /// Member transaction ids of every live `TransferSuggestion` record,
  /// maintained from `transferSuggestions.observeAll()` by
  /// `+SuggestionObservation.swift`. The transaction-detail banner
  /// reads this via `hasSuggestion(for:)` so SwiftUI re-renders
  /// automatically when a peer (or this device's dismiss / merge)
  /// deletes the record — the banner vanishes the moment the stream
  /// emits the shrunk set. Empty when no suggestion repository is
  /// wired (previews / legacy tests) or before the stream's first
  /// emission. Observed; written only via `setSuggestedTransactionIds`.
  private(set) var suggestedTransactionIds: Set<UUID> = []

  /// Observes `transferSuggestions.observeAll()` / `…observeErrors()`
  /// and keeps `suggestedTransactionIds` in sync. Spawned from `init`
  /// only when a suggestion repository is wired; torn down by
  /// `stopObserving()` / `deinit` alongside `rateObservationTask`.
  /// internal so `+SuggestionObservation.swift` manages its lifecycle
  /// (the same arrangement `subscriptionTask` has with `+Observation`).
  var suggestionObservationTask: Task<Void, Never>?

  /// Narrow seam onto the shared instrument registry's change stream.
  /// Per-profile list observations do not track the `instrument`
  /// table (identity is resolved once per fetch via the shared
  /// registry), so a metadata edit there does not re-fire the data
  /// observation. When wired, `instrumentChangeObservationTask`
  /// re-runs the imperative reload on each tick so an open list
  /// live-refreshes across the DB boundary. Nil in previews / legacy
  /// tests that don't exercise cross-DB instrument refresh.
  private let instrumentChanges: (any InstrumentChangeObserving)?

  /// Observes `instrumentChanges.observeChanges()` and re-fetches the
  /// active filter on each tick. Spawned from `init` only when a
  /// registry seam is wired; torn down by `stopObserving()` / `deinit`
  /// alongside `rateObservationTask`.
  private var instrumentChangeObservationTask: Task<Void, Never>?

  // internal so the `+TransferDetection` extension reaches it.
  /// Owns the merge / dismiss actions a transfer suggestion offers from
  /// the transaction-detail surface. Built once from the transaction
  /// repository and the transfer-suggestion repository the store is
  /// wired with. `nil` when the store is constructed without a
  /// transfer-suggestion repository (previews and legacy tests that
  /// never exercise transfer suggestions); the suggestion section
  /// self-hides and its actions no-op in that case.
  let transferDetection: TransferDetectionCoordinator?

  // internal so the `+TransferDetection` extension can resolve the
  // suggested counterpart of a transaction.
  /// Repository of detected transfer suggestions, used by the
  /// transaction-detail surface to resolve "is this transaction part of
  /// a suggested pair, and what is its counterpart?" via the synced
  /// record (never the denormalised model). `nil` in the same
  /// preview / legacy-test cases that leave `transferDetection` nil.
  let transferSuggestions: (any TransferSuggestionRepository)?

  /// The long-lived data-subscription task for the current filter. Owned
  /// by the store (not by the view's `.task`) so `load(filter:)` and
  /// `observe(filter:)` callers see the same active subscription, and
  /// mutations made between calls still get observation re-emissions.
  /// Replaced (with cancellation of the prior handle) on every filter
  /// change. internal so `+Observation` can manage the lifecycle.
  var subscriptionTask: Task<Void, Never>?

  /// Interval that `debouncedSave` waits before invoking the action.
  /// Production wires this from the default; tests pass `.zero` so the
  /// debounced task completes as soon as it's scheduled and can be
  /// awaited deterministically rather than via a wall-clock sleep.
  /// internal so `debouncedSave` (in `+Mutations.swift`) can read it.
  let debounceInterval: Duration

  /// Pending debounced save, cancelled and replaced by each
  /// `debouncedSave` call. internal so `debouncedSave` (in
  /// `+Mutations.swift`) can manage it — extensions cannot add stored
  /// properties, so the storage lives here.
  var saveTask: Task<Void, Never>?

  // MARK: - Lifecycle

  init(
    repository: TransactionRepository,
    conversionService: any InstrumentConversionService,
    targetInstrument: Instrument,
    pageSize: Int = 50,
    debounceInterval: Duration = .milliseconds(300),
    instrumentChanges: (any InstrumentChangeObserving)? = nil,
    transferSuggestions: (any TransferSuggestionRepository)? = nil
  ) {
    self.repository = repository
    self.payeeSuggestionSource = PayeeSuggestionSource(repository: repository)
    self.transferSuggestions = transferSuggestions
    if let transferSuggestions {
      self.transferDetection = TransferDetectionCoordinator(
        transactions: repository, suggestions: transferSuggestions)
    } else {
      self.transferDetection = nil
    }
    self.conversionService = conversionService
    self.targetInstrument = targetInstrument
    self.currentTargetInstrument = targetInstrument
    self.pageSize = pageSize
    self.debounceInterval = debounceInterval
    self.instrumentChanges = instrumentChanges
    let pair = AsyncStream<Void>.makeStream()
    self.testObservationTickStream = pair.stream
    self.testObservationTickContinuation = pair.continuation

    // Strong `self` capture is intentional: the store is `@MainActor`,
    // the task already holds an implicit strong reference, and
    // `stopObserving()` (called from `cleanupSync`) is the sole lifetime
    // gate. A weak capture would just add a nil-check hazard without
    // preventing the retain — and `guard let self else { return }` would
    // mask cancellation-propagation bugs by silently exiting.
    rateObservationTask = Task { await self.observeRateChannels() }
    startSuggestionObservation()
    if let instrumentChanges {
      let changes = instrumentChanges.observeChanges()
      instrumentChangeObservationTask = Task { [self] in
        await self.observeInstrumentRegistryChanges(changes)
      }
    }
  }

  deinit {
    // Safety net for the case where `cleanupSync` is missed (e.g. an
    // early-error tear-down path that drops the ProfileSession without
    // calling cleanupSync). Cancels the strongly-held observation Tasks
    // so they do not retain `self` and a stale GRDB connection forever.
    // Under normal lifecycle, `stopObserving()` runs first via
    // `cleanupSync` and this is a no-op. Swift 6 makes `deinit`
    // nonisolated; reading `@MainActor`-isolated state requires
    // `MainActor.assumeIsolated`. The store is owned by main-actor
    // code (`ProfileSession`), so the assumption holds in practice.
    MainActor.assumeIsolated {
      rateObservationTask?.cancel()
      suggestionObservationTask?.cancel()
      instrumentChangeObservationTask?.cancel()
      subscriptionTask?.cancel()
      subscriptionRestartContinuation?.finish()
      testObservationTickContinuation.finish()
      wakePendingLoadAwaiters()
    }
  }

  // MARK: - Public API

  /// View-driven entry point: subscribe to remote changes for `filter` and
  /// stream emissions into `transactions` until the surrounding `.task`
  /// is cancelled. Callers use `.task(id: filter) {
  /// await store.observe(filter: filter) }` — the `for await` loop lives
  /// here (per the thin-view rule from spec Section 5).
  func observe(filter: TransactionFilter) async {
    await runDataObservation(filter: filter)
  }

  /// Convenience for views keyed by a single account id (account-detail,
  /// embedded investment account list). Wraps `observe(filter:)` with the
  /// canonical per-account filter so the call site stays one line.
  func observe(accountId: UUID) async {
    await observe(filter: TransactionFilter(accountId: accountId))
  }

  /// Compatibility entry point. Restarts the active subscription with the
  /// supplied filter and returns once the first emission settles. Used by
  /// toolbar Refresh / `.refreshable` and by tests that want a synchronous-
  /// looking "load and assert" pattern. The view-driven `observe(filter:)`
  /// is the preferred way to drive observation; `load(filter:)` is a thin
  /// wrapper that yields the restart and waits one tick.
  func load(filter: TransactionFilter) async {
    await runImperativeReload(filter: filter)
  }

  /// Bumps the page window and signals the active subscription to
  /// resubscribe with the wider page size. Awaits the next observation
  /// emission so callers can assert against the wider page contents
  /// immediately. Idempotent when no more pages are available or
  /// another load is already in flight.
  func loadMore() async {
    guard !isLoading, hasMore else { return }
    pageWindow += 1
    loadGeneration &+= 1
    setIsLoading(true)
    subscriptionRestartContinuation?.yield(())
    await awaitNextLoadEmissionInternal()
  }

  /// Test-internal helper for `loadMore` and the imperative-reload path
  /// to wait for the next `applySnapshot` to wake them. Mirrors the
  /// inline body of `awaitNextLoadEmission` in `+Observation.swift`.
  func awaitNextLoadEmissionInternal() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      pendingLoadAwaiters.append(continuation)
    }
  }

  /// Tears down the rate-observation task and the data subscription.
  /// Idempotent. Called from
  /// `ProfileSession.cleanupSync(coordinator:)` AFTER any
  /// `deleteAllLocalData()` call so the empty-state transition is
  /// emitted to subscribed views before cancellation.
  ///
  /// Returns the moment `Task.cancel()` is issued — the underlying
  /// `for await` loops only notice cancellation on the next stream
  /// check. Tests asserting "no emission after stop" must call
  /// `awaitObservationTermination()` before the assertion.
  func stopObserving() {
    rateObservationTask?.cancel()
    suggestionObservationTask?.cancel()
    instrumentChangeObservationTask?.cancel()
    subscriptionTask?.cancel()
    subscriptionRestartContinuation?.finish()
    subscriptionRestartContinuation = nil
    // Wake any `load(filter:)` callers blocked on a first emission so
    // they don't hang past tear-down.
    wakePendingLoadAwaiters()
  }

  /// Test-only. Awaits the observation tasks to fully terminate after
  /// `stopObserving()`, then nils the references.
  func awaitObservationTermination() async {
    await rateObservationTask?.value
    rateObservationTask = nil
    await suggestionObservationTask?.value
    suggestionObservationTask = nil
    await instrumentChangeObservationTask?.value
    instrumentChangeObservationTask = nil
    await subscriptionTask?.value
    subscriptionTask = nil
  }

  // MARK: - Internal helpers used by `+Mutations.swift` and `+Observation.swift`

  func surface(observationError error: any Error) {
    logger.error("TransactionStore observation error: \(error.localizedDescription)")
    self.error = error
  }

  /// Mutator hooks invoked by extension files (which live in the same
  /// module but separate files, so `private(set)` properties on the
  /// main type are not directly assignable from there).
  func setCurrentFilter(_ filter: TransactionFilter) { currentFilter = filter }
  func setCurrentTargetInstrument(_ instrument: Instrument) {
    currentTargetInstrument = instrument
  }
  func setTransactions(_ rows: [TransactionWithBalance]) {
    unfilteredTransactions = rows
    publishFilteredTransactions()
  }
  // Used by `+SpamFilter.swift` to write `transactions` (private(set)).
  func setFilteredTransactions(_ rows: [TransactionWithBalance]) { transactions = rows }
  // Used by `+SpamFilter.swift` to write `spamInstruments` (private(set)).
  func setSpamInstrumentsValue(_ value: Set<Instrument>) { spamInstruments = value }

  func setHasMore(_ value: Bool) { hasMore = value }
  func setError(_ error: (any Error)?) { self.error = error }
  func setLoadedCount(_ count: Int) { loadedCount = count }
  func setTotalCount(_ count: Int?) { totalCount = count }
  func setIsLoading(_ value: Bool) { isLoading = value }
  func setIsPayingScheduled(_ value: Bool) { isPayingScheduled = value }
  func setSuggestedTransactionIds(_ ids: Set<UUID>) {
    suggestedTransactionIds = ids
  }
}
