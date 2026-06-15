import Foundation
import OSLog
import Observation

@Observable
@MainActor
final class EarmarkStore {

  // MARK: - State

  private(set) var earmarks = Earmarks(from: [])
  private(set) var error: Error?

  // Budget storage stays mutable from the `+Budget` extension; the
  // budget surface is still imperative (loadBudget / updateBudgetItem /
  // …) and pre-dates the reactive migration. Subsequent UI work will
  // adopt `repository.observeBudget(earmarkId:)`.
  var budgetItems: [EarmarkBudgetItem] = []
  var isBudgetLoading = false
  var budgetError: Error?

  private(set) var convertedTotalBalance: InstrumentAmount?
  private(set) var convertedBalances: [UUID: InstrumentAmount] = [:]
  private(set) var convertedSavedAmounts: [UUID: InstrumentAmount] = [:]
  private(set) var convertedSpentAmounts: [UUID: InstrumentAmount] = [:]

  // internal (not `private`): `repository` is used by `+Budget` and
  // `+Mutations`; `conversionService` is used by `+Conversion`. All three
  // extensions need cross-file access that `private` would block.
  let repository: EarmarkRepository
  let conversionService: any InstrumentConversionService
  let targetInstrument: Instrument
  /// Delay between retry attempts after a conversion failure. Production
  /// uses ~30s; tests pass a small value to keep retries snappy.
  private let retryDelay: Duration
  // internal (not `private`) so the `+Budget` and `+Mutations` extensions
  // can log under the same subsystem/category.
  let logger = Logger(subsystem: "com.moolah.app", category: "EarmarkStore")

  /// The single observation `Task` that runs the `withTaskGroup` of
  /// child tasks subscribing to `repository.observeAll()`,
  /// `repository.observeErrors()`, `conversionService.observeRates()`,
  /// and `conversionService.observeErrors()`. Spawned from `init`,
  /// torn down by `stopObserving()` (called from
  /// `ProfileSession.cleanupSync`) or by `deinit` as a safety net.
  private var observationTask: Task<Void, Never>?

  /// Narrow seam onto the shared instrument registry's change stream.
  /// The earmarks observation does not track the `instrument` table
  /// (identity resolved once per fetch via the shared registry), so a
  /// metadata edit there does not re-fire `observeAll()`. When wired,
  /// `instrumentChangeObservationTask` re-fetches earmarks and
  /// re-applies on each registry tick so an open earmark list
  /// live-refreshes across the DB boundary. Nil in previews / legacy
  /// tests.
  private let instrumentChanges: (any InstrumentChangeObserving)?

  /// Observes `instrumentChanges.observeChanges()` and refreshes the
  /// earmarks list on each tick. Spawned from `init` only when a
  /// registry seam is wired; torn down by `stopObserving()` / `deinit`
  /// alongside `observationTask`.
  private var instrumentChangeObservationTask: Task<Void, Never>?

  /// Monotonic counter over authoritative `observeAll()` snapshots. The
  /// instrument-registry refresh path captures it before its `fetchAll()`
  /// and drops a stale refetch that raced a fresher snapshot — see
  /// `applyInstrumentRegistryRefresh` (mirrors `AccountStore`). `private(set)`
  /// (only `bumpSnapshotGeneration()` writes it) + `@ObservationIgnored`
  /// (a pure guard counter no view reads).
  @ObservationIgnored private(set) var snapshotGeneration: UInt64 = 0

  /// The single increment path for `snapshotGeneration` — internal so the
  /// `+Observation` apply shim can reach it past the property's `private(set)`.
  func bumpSnapshotGeneration() {
    snapshotGeneration &+= 1
  }

  /// Background retry loop spawned by `recomputeConvertedTotals()` when
  /// a conversion pass reports any failure. Cancelled when a subsequent
  /// pass succeeds; otherwise continues until success or the store is
  /// torn down. See the conditional-cancel pattern below.
  private var conversionTask: Task<Void, Never>?

  /// Test-only emission tick stream. Yields `()` after every state
  /// assignment in `apply(earmarks:)` and after every recompute in
  /// `recomputeConvertedTotals()`. Tests use the
  /// `TestableStoreObservation` helpers in
  /// `MoolahTests/Support/TestableStoreObservation.swift` to await
  /// emissions deterministically. `internal` access is intentional;
  /// `@testable import Moolah` exposes it to the test target.
  let testObservationTickStream: AsyncStream<Void>
  private let testObservationTickContinuation: AsyncStream<Void>.Continuation

  // MARK: - Lifecycle

  init(
    repository: EarmarkRepository,
    conversionService: any InstrumentConversionService,
    targetInstrument: Instrument,
    retryDelay: Duration = .seconds(30),
    instrumentChanges: (any InstrumentChangeObserving)? = nil
  ) {
    self.repository = repository
    self.conversionService = conversionService
    self.targetInstrument = targetInstrument
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

  // MARK: - Observation & State Updates

  /// Applies a fresh earmarks snapshot from `observeAll()`. Wrapped in
  /// the Layer 7 signpost interval so benchmarks and Instruments traces
  /// can attribute `mainThreadMs` to this method. The nested
  /// `recomputeConvertedTotals` call has its own signpost; the outer
  /// interval includes both bodies. internal (default) so the sibling
  /// `+Observation` extension file can drive it from the reactive
  /// streams.
  func apply(earmarks fresh: [Earmark]) async {
    await withReactiveStoreSignpost("earmark-store-apply") {
      self.earmarks = Earmarks(from: fresh)
      await recomputeConvertedTotals()
      testObservationTickContinuation.yield(())
    }
  }

  /// Surfaces an observation error onto `self.error`. internal (default)
  /// so the sibling `+Observation` extension file can call it from the
  /// per-stream error tasks.
  func surface(error: any Error) {
    logger.error("EarmarkStore observation error: \(error.localizedDescription)")
    self.error = error
  }

  /// Tears down the observation task. Idempotent. Called from
  /// `ProfileSession.cleanupSync(coordinator:)` AFTER any
  /// `deleteAllLocalData()` call so the empty-state transition is
  /// emitted to subscribed views before cancellation.
  ///
  /// Returns the moment `Task.cancel()` is issued — the underlying
  /// `for await` loops in `observe()` only notice cancellation on the
  /// next stream check, so an in-flight emission can race the cancel.
  /// Tests asserting "no emission after stop" must call
  /// `awaitObservationTermination()` between this method and the
  /// assertion. Production callers (`cleanupSync`) don't need
  /// determinism — no backend writes happen after teardown.
  func stopObserving() {
    observationTask?.cancel()
    instrumentChangeObservationTask?.cancel()
    conversionTask?.cancel()
    showHiddenTask?.cancel()
  }

  /// Test-only. Awaits the observation task chain to fully terminate
  /// after `stopObserving()`, then nils the references. See
  /// `stopObserving()` for the race this exists to close.
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
      // The grand total sums only `visibleEarmarks`; without this recompute
      // the "Earmarked Total" stays pinned to the previous visibility's sum
      // until the next observation tick.
      guard oldValue != showHidden else { return }
      showHiddenTask?.cancel()
      showHiddenTask = Task { await recomputeConvertedTotals() }
    }
  }

  var visibleEarmarks: [Earmark] {
    earmarks.filter { showHidden || !$0.isHidden }
  }

  /// Applies position deltas to earmark balances, saved, and spent.
  /// Used by `TransactionStore` to keep the sidebar fresh between a
  /// write and the next observation emission. The reactive observation
  /// will overwrite this state with authoritative GRDB content shortly
  /// after; the delta keeps the UI snappy in the interim.
  func applyDelta(
    earmarkDeltas: PositionDeltas,
    savedDeltas: PositionDeltas,
    spentDeltas: PositionDeltas
  ) async {
    var result = earmarks
    let allIds = Set(earmarkDeltas.keys).union(savedDeltas.keys).union(spentDeltas.keys)
    for earmarkId in allIds {
      result = result.adjustingPositions(
        of: earmarkId,
        positionDeltas: earmarkDeltas[earmarkId] ?? [:],
        savedDeltas: savedDeltas[earmarkId] ?? [:],
        spentDeltas: spentDeltas[earmarkId] ?? [:]
      )
    }
    earmarks = result
    await recomputeConvertedTotals()
  }

  /// Recompute per-earmark balances and the aggregate total. Driven by
  /// emissions from either `repository.observeAll()` (fresh data) or
  /// `conversionService.observeRates()` (rate changes). The first pass
  /// publishes inline. If the pass reports any conversion failure and
  /// no retry loop is already running, a `@MainActor` background retry
  /// is spawned that keeps attempting until everything succeeds.
  ///
  /// Conditional cancel: the retry is cancelled only on success.
  /// Leaving it running on repeat failure is intentional — every
  /// emission from either source would otherwise reset the clock and a
  /// profile with frequent unrelated rate ticks could delay recovery
  /// indefinitely.
  ///
  /// Each earmark is converted in isolation: a failure for one leaves
  /// other earmarks' balances populated. The aggregate
  /// `convertedTotalBalance` is only published when *all* contributing
  /// earmarks succeed (an inaccurate total is worse than no total).
  func recomputeConvertedTotals() async {
    let anyFailed = await withReactiveStoreSignpost("earmark-store-recompute") {
      let failed = await runConversionAttempt()
      testObservationTickContinuation.yield(())
      return failed
    }
    if !anyFailed {
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
    // `self.conversionTask` and yields the test tick (both
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
        let retryFailed = await self.runConversionAttempt()
        self.testObservationTickContinuation.yield(())
        if !retryFailed {
          self.conversionTask = nil
          return
        }
      }
    }
  }

  /// Awaits the background retry loop, if one is running. Only relevant
  /// after a first pass that hit a conversion failure — returns
  /// immediately when the store has no retry task pending. When a retry
  /// loop is running, this returns when it terminates (which happens
  /// only when a retry pass succeeds, or a new recompute cancels the
  /// loop).
  func waitForPendingConversions() async {
    guard let task = conversionTask else { return }
    await task.value
  }

  /// Single pass over every earmark; returns `true` if any conversion
  /// failed. Always publishes the latest computed state, even if partial.
  ///
  /// Iterates all earmarks (not just `visibleEarmarks`) so per-earmark
  /// balances populate regardless of `showHidden` — otherwise toggling
  /// "Show Hidden" surfaces a permanent spinner on hidden rows that no
  /// recompute ever filled in. The grand total still sums only visible
  /// earmarks so it matches what the user sees.
  private func runConversionAttempt() async -> Bool {
    var anyFailed = false
    var balances: [UUID: InstrumentAmount] = [:]
    var saved: [UUID: InstrumentAmount] = [:]
    var spent: [UUID: InstrumentAmount] = [:]
    var grandTotal = InstrumentAmount.zero(instrument: targetInstrument)
    var grandTotalValid = true
    let zeroInTarget = InstrumentAmount.zero(instrument: targetInstrument)

    for earmark in earmarks {
      let isVisible = showHidden || !earmark.isHidden
      do {
        let totals = try await convertEarmarkPositions(earmark)
        guard !Task.isCancelled else { return false }
        balances[earmark.id] = totals.balance
        saved[earmark.id] = totals.saved
        spent[earmark.id] = totals.spent

        // Only visible earmarks contribute to the displayed grand total.
        // Clamp negative balances to zero so they don't reduce the total.
        if isVisible, grandTotalValid {
          let convertedToTarget = try await conversionService.convertAmount(
            totals.balance, to: targetInstrument, on: Date())
          guard !Task.isCancelled else { return false }
          grandTotal += max(convertedToTarget, zeroInTarget)
        }
      } catch {
        anyFailed = true
        // A failure on a hidden earmark shouldn't blank the total — only
        // visible earmarks contribute to it. Hidden-earmark failures still
        // mark `anyFailed` so the retry loop kicks in (and a later toggle
        // doesn't surface a spinner because no retry was scheduled).
        if isVisible { grandTotalValid = false }
        logger.warning(
          "Conversion failed for earmark \(earmark.name): \(error.localizedDescription)")
      }
    }

    guard !Task.isCancelled else { return false }

    convertedBalances = balances
    convertedSavedAmounts = saved
    convertedSpentAmounts = spent
    convertedTotalBalance = grandTotalValid ? grandTotal : nil

    return anyFailed
  }

  // Read-only query accessors live in `EarmarkStore+Queries.swift`.
  // Per-earmark conversion helpers live in `EarmarkStore+Conversion.swift`.
  // Mutation methods live in `EarmarkStore+Mutations.swift`.
  // Budget CRUD lives in `EarmarkStore+Budget.swift`.

  /// Module-internal hook used by `EarmarkStore+Mutations.swift` to
  /// surface and reset the published `error` property. Lives here
  /// (rather than on the extension) because `error` is `private(set)`
  /// — the extension cannot mutate it directly.
  func setError(_ error: (any Error)?) {
    self.error = error
  }
}
