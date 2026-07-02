import Foundation
import OSLog
import Observation

@Observable
@MainActor
final class AccountStore {
  private(set) var accounts = Accounts(from: [])
  private(set) var error: Error?

  private(set) var convertedCurrentTotal: InstrumentAmount?
  private(set) var convertedInvestmentTotal: InstrumentAmount?
  private(set) var convertedNetWorth: InstrumentAmount?

  /// Per-account display balance (sum of positions converted to the
  /// account's own instrument), updated by `recomputeConvertedTotals`.
  /// An entry is absent if conversion failed for any of the account's
  /// positions; per the bug fix, we never display a partial balance.
  private(set) var convertedBalances: [UUID: InstrumentAmount] = [:]

  /// Externally-set values for investment accounts (e.g. mark-to-market share
  /// prices set via `InvestmentStore`). Read-through to `investmentValueCache`
  /// so existing call sites can continue to inspect the map directly.
  var investmentValues: [UUID: InstrumentAmount] { investmentValueCache.values }

  /// True once at least one conversion pass has completed, regardless of
  /// success or failure. Views use this to distinguish "still loading"
  /// from "conversion ran and produced no balance".
  private(set) var hasCompletedInitialConversion: Bool = false

  // `repository`, `conversionService`, and `investmentRepository` are
  // deliberately not `private` so the sibling `+Observation.swift`
  // extension can subscribe to their reactive streams. Treat them as
  // private-by-convention from elsewhere in the module.
  let repository: AccountRepository
  let conversionService: any InstrumentConversionService
  let targetInstrument: Instrument
  /// Investment repository — captured separately from the read-through
  /// cache so the observation pipeline can subscribe to its
  /// `observeAllValues()` tick stream. `nil` in tests / previews that
  /// don't pass an investment repository (no investment-value writes
  /// will reach the store; `convertedInvestmentTotal` falls back to the
  /// position sum).
  let investmentRepository: (any InvestmentRepository)?
  /// Read-through cache of externally-set investment values. `internal`
  /// (rather than `private`) so the `+ConvertedTotals.swift` extension
  /// file can pass it to the balance calculator without a wrapper.
  let investmentValueCache: InvestmentValueCache
  /// `internal` so the `+ConvertedTotals.swift` extension can call the
  /// calculator directly. Stays `let` — mutating it externally would
  /// invalidate the retry loop's invariants.
  let balanceCalculator: AccountBalanceCalculator
  /// Delay between retry attempts after a conversion failure. Production
  /// uses ~30s; tests pass a small value to keep retries snappy.
  private let retryDelay: Duration
  private let logger = Logger(subsystem: "com.moolah.app", category: "AccountStore")

  /// The single observation `Task` that runs the `withTaskGroup` of
  /// child tasks subscribing to `repository.observeAll()`,
  /// `repository.observeErrors()`, `conversionService.observeRates()`,
  /// and `conversionService.observeErrors()`. Spawned from `init`,
  /// torn down by `stopObserving()` (called from
  /// `ProfileSession.cleanupSync`) or by `deinit` as a safety net.
  private var observationTask: Task<Void, Never>?

  /// Shared instrument-registry change seam + the child task draining
  /// it (see `+Observation`). Nil in previews / legacy tests.
  private let instrumentChanges: (any InstrumentChangeObserving)?
  private var instrumentChangeObservationTask: Task<Void, Never>?

  /// Monotonic counter over authoritative `observeAll()` snapshots. Two
  /// sites capture it before suspending and drop their work if a fresher
  /// authoritative snapshot lands while they are suspended:
  ///   - the instrument-registry refresh path, before its `fetchAll()` —
  ///     see `applyInstrumentRegistryRefresh`;
  ///   - the balance-recompute path, before it suspends in the conversion
  ///     service — see `publishSnapshot(_:ifGeneration:)` and issue #1209.
  /// `private(set)` (only `bumpSnapshotGeneration()` writes it) +
  /// `@ObservationIgnored` (a pure guard counter no view reads).
  @ObservationIgnored private(set) var snapshotGeneration: UInt64 = 0

  /// The single increment path for `snapshotGeneration`. Internal so the
  /// authoritative apply shim in the sibling `+Observation` file can call
  /// it; combined with the property's `private(set)`, every other site is
  /// barred from mutating the guard counter at compile time.
  func bumpSnapshotGeneration() {
    snapshotGeneration &+= 1
  }

  /// Background retry loop spawned by `recomputeConvertedTotals()` when
  /// a conversion pass reports any failure. Cancelled when a subsequent
  /// pass succeeds; otherwise continues until success or the store is
  /// torn down. See the conditional-cancel pattern below.
  private var conversionTask: Task<Void, Never>?

  /// Test-only emission tick stream. Yields `()` after every state
  /// assignment in `apply(accounts:)` and after every recompute in
  /// `recomputeConvertedTotals()`. Tests use the
  /// `TestableStoreObservation` helpers in
  /// `MoolahTests/Support/TestableStoreObservation.swift` to await
  /// emissions deterministically. `internal` access is intentional;
  /// `@testable import Moolah` exposes it to the test target.
  let testObservationTickStream: AsyncStream<Void>
  private let testObservationTickContinuation: AsyncStream<Void>.Continuation

  /// Cumulative wall-clock time (in nanoseconds) consumed by the
  /// `apply(accounts:)` body since the store was constructed. Sampled
  /// by `SyncReactivityBenchmarks` (also `@MainActor`) to verify the
  /// Layer 7 acceptance criterion "main-thread time < 50 ms cumulative"
  /// without standing up an `OSSignpostListener` (which needs
  /// Instruments tooling and doesn't work cleanly inside an XCTest
  /// harness). The production app never reads it.
  private(set) var testApplyMainThreadNanos: UInt64 = 0

  init(
    repository: AccountRepository,
    conversionService: any InstrumentConversionService,
    targetInstrument: Instrument,
    investmentRepository: (any InvestmentRepository)? = nil,
    retryDelay: Duration = .seconds(30),
    instrumentChanges: (any InstrumentChangeObserving)? = nil
  ) {
    self.repository = repository
    self.conversionService = conversionService
    self.targetInstrument = targetInstrument
    self.investmentRepository = investmentRepository
    self.investmentValueCache = InvestmentValueCache(repository: investmentRepository)
    self.balanceCalculator = AccountBalanceCalculator(
      conversionService: conversionService, targetInstrument: targetInstrument)
    self.retryDelay = retryDelay
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
    observationTask = Task { await self.observe() }
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
    // calling cleanupSync). Cancels the strongly-held observation Task
    // so it does not retain `self` and a stale GRDB connection forever.
    // Under normal lifecycle, `stopObserving()` runs first via
    // `cleanupSync` and this is a no-op. Swift 6 makes `deinit`
    // nonisolated; reading `@MainActor`-isolated state requires
    // `MainActor.assumeIsolated`. The store is owned by main-actor
    // code (`ProfileSession`), so the assumption holds in practice.
    MainActor.assumeIsolated {
      observationTask?.cancel()
      instrumentChangeObservationTask?.cancel()
      conversionTask?.cancel()
      showHiddenTask?.cancel()
      testObservationTickContinuation.finish()
    }
  }

  // MARK: - Observation support (entry-point shims live in `+Observation.swift`)

  /// Applies a fresh accounts snapshot from `observeAll()`. Wrapped in
  /// the Layer 7 signpost 4 interval so `SyncReactivityBenchmarks` and
  /// Instruments traces can attribute `mainThreadMs` to this method.
  /// The nested `recomputeConvertedTotals` call has its own signpost;
  /// the outer interval includes both bodies plus `preloadInvestmentValues`.
  /// Internal (not `private`) so the entry-point shims in
  /// `+Observation.swift` can drive it across the file split.
  func apply(accounts fresh: [Account]) async {
    await withReactiveStoreSignpost("account-store-apply") {
      let started = ContinuousClock.now
      self.accounts = Accounts(from: fresh)
      await preloadInvestmentValues()
      await recomputeConvertedTotals()
      testObservationTickContinuation.yield(())
      testApplyMainThreadNanos &+= nanoseconds(since: started)
    }
  }

  /// Internal (not `private`) so `surfaceObservationError` in
  /// `+Observation.swift` can route per-stream errors here.
  func surface(error: any Error) {
    logger.error("AccountStore observation error: \(error.localizedDescription)")
    self.error = error
  }

  /// Tears down the observation task. Idempotent. Called from
  /// `ProfileSession.cleanupSync(coordinator:)` AFTER any
  /// `deleteAllLocalData()` call so the empty-state transition is
  /// emitted to subscribed views before cancellation.
  ///
  /// Returns the moment `Task.cancel()` is issued — the underlying
  /// `for await` loops only notice cancellation on the next stream
  /// check, so an in-flight emission can race the cancel. Tests
  /// asserting "no emission after stop" must call
  /// `awaitObservationTermination()` before the assertion. Production
  /// callers (`cleanupSync`) don't need determinism — no backend writes
  /// happen after teardown.
  func stopObserving() {
    observationTask?.cancel()
    instrumentChangeObservationTask?.cancel()
    conversionTask?.cancel()
    showHiddenTask?.cancel()
  }

  /// Test-only. Awaits the observation task chain to fully terminate
  /// after `stopObserving()`, then nils the references.
  func awaitObservationTermination() async {
    await observationTask?.value
    observationTask = nil
    await instrumentChangeObservationTask?.value
    instrumentChangeObservationTask = nil
    await conversionTask?.value
    conversionTask = nil
    await showHiddenTask?.value
    showHiddenTask = nil
  }

  /// Recompute task spawned by the `showHidden` `didSet`. Tracked (not
  /// fire-and-forget) so `stopObserving()` and `deinit` can cancel an
  /// in-flight recompute. A rapid double-toggle cancels the prior task
  /// before spawning the next, narrowing the window for stale writes.
  private var showHiddenTask: Task<Void, Never>?

  var showHidden: Bool = false {
    didSet {
      // Aggregate totals filter on `showHidden`; without this recompute they
      // stay pinned to the previous visibility's sum until the next tick.
      guard oldValue != showHidden else { return }
      showHiddenTask?.cancel()
      // `@MainActor in` for the same future-refactor safety reason as the
      // retry task below — see the note on `conversionTask`.
      showHiddenTask = Task { @MainActor in await recomputeConvertedTotals() }
    }
  }

  // Read-only query helpers (`currentAccounts`, `investmentAccounts`,
  // `displayBalance`, `hasUnrecordedValue`, `canDelete`, `positions(for:)`)
  // live in `AccountStore+Queries.swift`.

  /// Recompute per-account balances and aggregate totals via
  /// `balanceCalculator`. Driven by emissions from either
  /// `repository.observeAll()` (fresh data) or
  /// `conversionService.observeRates()` (rate changes). The first pass
  /// publishes inline. If the pass reports any conversion failure and
  /// no retry loop is already running, a `@MainActor` background retry
  /// is spawned that keeps attempting until everything succeeds.
  ///
  /// Conditional cancel: the retry is cancelled only on success. Leaving
  /// it running on repeat failure is intentional — every emission from
  /// either source would otherwise reset the clock and a profile with
  /// frequent unrelated rate ticks could delay recovery indefinitely.
  func recomputeConvertedTotals() async {
    // Capture the authoritative-snapshot generation *before* reading
    // `accounts` (no suspension intervenes, so the two are consistent).
    // `publishSnapshot` drops this pass if a fresher `observeAll()`
    // snapshot lands while `computeBalanceSnapshot` is suspended in the
    // conversion service — otherwise a recompute that read a stale
    // accounts snapshot (classically the startup rate-tick pass over the
    // empty initial accounts) can publish *after* the authoritative
    // accounts recompute and clobber it back to a pre-snapshot state.
    // Same guard, same rationale as `applyInstrumentRegistryRefresh`.
    // See issue #1209.
    let generation = snapshotGeneration
    // Layer 7 signpost 4 (recompute path). Region covers the balance
    // compute + main-thread publish; the retry-loop spawn that follows
    // on failure is outside the region (background work). When called
    // from `apply(accounts:)`, this region nests inside the outer
    // `account-store-apply` interval.
    let snapshot = await withReactiveStoreSignpost("account-store-recompute") {
      let snap = await computeBalanceSnapshot()
      publishSnapshot(snap, ifGeneration: generation)
      testObservationTickContinuation.yield(())
      return snap
    }
    if !snapshot.anyFailed {
      // Success — kill any in-flight retry; nothing left to retry.
      conversionTask?.cancel()
      conversionTask = nil
      return
    }
    // Failure — start a retry only if one isn't already running.
    // Critical: the `guard conversionTask == nil else { return }` line
    // is load-bearing. Without it, every emission from observeRates()
    // (including writes for instruments unrelated to this profile) would
    // cancel and respawn the retry loop, resetting the wait clock and
    // potentially delaying recovery indefinitely.
    guard conversionTask == nil else { return }
    let delay = retryDelay
    // `Task { @MainActor in … }`: the closure mutates
    // `self.conversionTask` and calls `publishSnapshot` (both
    // MainActor-isolated). The annotation is required even though the
    // call site is already on `@MainActor` — future refactors that move
    // `recomputeConvertedTotals` off MainActor would silently introduce
    // a race without the explicit annotation.
    conversionTask = Task { @MainActor in
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: delay)
        } catch {
          return  // CancellationError — exit the retry loop immediately
        }
        guard !Task.isCancelled else { return }
        // Re-capture per iteration: an accounts change during the delay
        // bumps the generation, so a retry that raced a fresher snapshot
        // drops its publish rather than clobbering it (see #1209).
        let generation = self.snapshotGeneration
        let retry = await self.computeBalanceSnapshot()
        guard !Task.isCancelled else { return }
        self.publishSnapshot(retry, ifGeneration: generation)
        self.testObservationTickContinuation.yield(())
        if !retry.anyFailed {
          self.conversionTask = nil
          return
        }
      }
    }
  }

  private func computeBalanceSnapshot() async -> AccountBalanceCalculator.Snapshot {
    await balanceCalculator.compute(
      allAccounts: accounts.ordered,
      currentAccounts: currentAccounts,
      investmentAccounts: investmentAccounts,
      investmentValues: investmentValueCache)
  }

  /// Publishes a computed snapshot, unless a fresher authoritative
  /// accounts snapshot has landed since the recompute captured
  /// `generation`. Dropping a stale pass is what stops an out-of-order
  /// publish from clobbering the current state — see the capture site in
  /// `recomputeConvertedTotals` and issue #1209. A dropped pass leaves
  /// `hasCompletedInitialConversion` to the fresher pass that superseded
  /// it (which sets it), so the "still loading" flag never regresses.
  private func publishSnapshot(
    _ snapshot: AccountBalanceCalculator.Snapshot, ifGeneration generation: UInt64
  ) {
    guard snapshotGeneration == generation else { return }
    convertedBalances = snapshot.balances
    convertedCurrentTotal = snapshot.currentTotal
    convertedInvestmentTotal = snapshot.investmentTotal
    convertedNetWorth = snapshot.netWorth
    hasCompletedInitialConversion = true
  }

  /// Awaits the background retry loop, if one is running. Only relevant
  /// after a first pass that hit a conversion failure — returns immediately
  /// when the store has no retry task pending. When a retry loop is running,
  /// this returns when it terminates (which happens only when a retry pass
  /// succeeds, or a new recompute cancels the loop).
  func waitForPendingConversions() async {
    guard let task = conversionTask else { return }
    await task.value
  }

  /// Applies position deltas to account balances. Used by
  /// `TransactionStore` to keep the sidebar fresh between a write and
  /// the next observation emission. The reactive observation will
  /// overwrite this state with authoritative GRDB content shortly
  /// after; the delta keeps the UI snappy in the interim.
  func applyDelta(_ accountDeltas: PositionDeltas) async {
    var result = accounts
    for (accountId, instrumentDeltas) in accountDeltas {
      result = result.adjustingPositions(of: accountId, by: instrumentDeltas)
    }
    accounts = result
    await recomputeConvertedTotals()
  }

  // Mutation methods live in `AccountStore+Mutations.swift`.

  /// Module-internal hook used by `AccountStore+Mutations.swift` to
  /// surface and reset the published `error` property. Lives here
  /// (rather than on the extension) because `error` is `private(set)`
  /// — the extension cannot mutate it directly.
  func setError(_ error: (any Error)?) {
    self.error = error
  }

  /// Module-internal helper for `AccountStore+Mutations.swift` to log
  /// against the shared logger.
  var mutationLogger: Logger { logger }

  /// Module-internal accessor for `AccountStore+Mutations.swift` to
  /// reach the underlying repository.
  var mutationRepository: AccountRepository { repository }
}
