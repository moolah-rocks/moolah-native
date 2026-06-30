import Foundation
import OSLog

// Reactive observation pipeline for `TransactionStore`.
//
// Two observation surfaces participate:
//   1. `repository.observe(filter:page:pageSize:)` — the per-filter
//      data stream. Drives the `transactions` array. Owned by
//      `subscriptionTask`, started lazily on the first
//      `observe(filter:)` / `load(filter:)` call and replaced when the
//      filter or page window changes.
//   2. `conversionService.observeRates()` — the rate-cache tick. Drives
//      a running-balance recompute against the most recent snapshot.
//      Owned by `rateObservationTask`, spawned from `init`.
//
// `repository.observe(...)` returns a `TransactionPage` whose
// `priorBalance` is intentionally `nil` (the repository drops it
// because the conversion-service hop is async). This extension calls
// `repository.fetch(...)` after each observation tick to obtain the
// authoritative `priorBalance` — mirroring the imperative path.
extension TransactionStore {
  /// Reason a recompute pass was triggered. Carried into the running-
  /// balance pipeline so logs and signposts can attribute work back to
  /// its source.
  enum RecomputeReason {
    case freshSnapshot
    case rateTick
  }

  /// View-driven entry point: ensure a subscription is running for
  /// `filter` and hold the calling `.task` open until it's cancelled.
  /// The `for await` loop lives inside the spawned `subscriptionTask`,
  /// not here — this method just gates the `.task`'s lifetime against
  /// the underlying subscription.
  func runDataObservation(filter: TransactionFilter) async {
    ensureSubscription(for: filter)
    let waiter = subscriptionTask
    // `await waiter?.value` would return as soon as the subscription
    // task finishes. Under the cancel-on-filter-change pattern, when a
    // newer call replaces the subscription task, the OLD task is
    // cancelled and finishes — but the caller of THIS observe(filter:)
    // is for the SAME filter as the live subscription, so it should
    // stay parked until either the surrounding `.task` is cancelled
    // (propagating cancellation through `await`) or `stopObserving()`
    // tears the subscription down.
    await waiter?.value
  }

  /// Explicit reload: ensures a subscription is running for `filter`,
  /// then issues a direct `repository.fetch(...)` so the call site sees
  /// the snapshot before returning. The reactive subscription continues
  /// in the background to deliver future updates. Used by toolbar
  /// Refresh, `.refreshable`, and tests that want a synchronous-looking
  /// "load and assert" pattern.
  func runImperativeReload(filter: TransactionFilter) async {
    ensureSubscription(for: filter)
    // For an unchanged-filter refresh `ensureSubscription` is a no-op —
    // bump the generation and the loading flag so superseded fetches
    // exit cleanly and the UI's progress indicator shows.
    loadGeneration &+= 1
    setIsLoading(true)
    let myGeneration = loadGeneration
    let windowedPageSize = pageSize * pageWindow
    do {
      let snapshot = try await repository.fetch(
        filter: filter, page: 0, pageSize: windowedPageSize)
      guard !Task.isCancelled, myGeneration == loadGeneration,
        filter == currentFilter
      else {
        // Superseded — clear isLoading so a re-mount that follows
        // doesn't see a stale loading indicator. See #412 sibling case
        // in the legacy `fetchPage` path.
        if myGeneration == loadGeneration { setIsLoading(false) }
        return
      }
      await applySnapshot(
        snapshot, observedCount: snapshot.transactions.count, fetchMs: 0)
    } catch is CancellationError {
      // View teardown / supersession. Mirror the legacy `fetchPage`
      // contract: don't latch `isLoading` past the cancel so a
      // subsequent re-mount can issue its own load. The CancellationError
      // is intentionally not surfaced — it's a normal lifecycle event.
      if myGeneration == loadGeneration { setIsLoading(false) }
      return
    } catch {
      guard myGeneration == loadGeneration, filter == currentFilter else { return }
      logger.error("Failed to refresh transactions: \(error.localizedDescription)")
      setError(error)
      setIsLoading(false)
      wakePendingLoadAwaiters()
    }
  }

  /// (Re)spawns `subscriptionTask` so it's running for `filter` with
  /// `pageWindow == 1`. Cancels any prior subscription.
  func ensureSubscription(for filter: TransactionFilter) {
    if filter == currentFilter, subscriptionTask?.isCancelled == false { return }
    subscriptionTask?.cancel()
    setupForFilter(filter)
    let (kickStream, kickContinuation) = AsyncStream<Void>.makeStream()
    subscriptionRestartContinuation?.finish()
    subscriptionRestartContinuation = kickContinuation
    let capturedFilter = filter
    subscriptionTask = Task { [self] in
      await self.driveSubscription(filter: capturedFilter, kickStream: kickStream)
      // Subscription terminated (cancellation or natural finish without
      // emissions). Wake any `load(filter:)` callers parked on
      // `pendingLoadAwaiters` so they don't hang past tear-down.
      await MainActor.run { self.wakePendingLoadAwaiters() }
    }
  }

  /// Resumes every pending `load(filter:)` continuation. Called from
  /// `applySnapshot`, the error path of `handleObservedPage`, and the
  /// post-completion cleanup of `subscriptionTask`. internal so the
  /// subscription closure can call into `@MainActor`-isolated state.
  func wakePendingLoadAwaiters() {
    let awaiters = pendingLoadAwaiters
    pendingLoadAwaiters.removeAll()
    for awaiter in awaiters { awaiter.resume() }
  }

  /// Inner subscription driver — keeps re-subscribing whenever the
  /// kick channel signals (loadMore / explicit refresh). Returns when
  /// cancelled or when the data stream finishes naturally.
  private func driveSubscription(
    filter: TransactionFilter, kickStream: AsyncStream<Void>
  ) async {
    while !Task.isCancelled {
      let didCompleteNaturally = await runOneSubscriptionCycle(
        filter: filter, kickStream: kickStream)
      if didCompleteNaturally { return }
    }
  }

  /// Runs a single subscription cycle for the active `(filter,
  /// pageWindow)`. Races the `for await page in ...` against the
  /// `kickStream` so a `loadMore()` (or explicit refresh) can interrupt
  /// the inner stream and let the outer loop restart with the new
  /// window. Returns `true` when the stream ended naturally
  /// (cancellation / finished); `false` when a restart was requested.
  private func runOneSubscriptionCycle(
    filter: TransactionFilter, kickStream: AsyncStream<Void>
  ) async -> Bool {
    let windowedPageSize = pageSize * pageWindow
    let stream = repository.observe(
      filter: filter, page: 0, pageSize: windowedPageSize)
    let myFilter = filter
    return await withTaskGroup(of: CycleOutcome.self) { group -> Bool in
      group.addTask { [self] in
        for await page in stream {
          await self.handleObservedPage(page, filter: myFilter)
        }
        return .streamFinished
      }
      group.addTask {
        var iter = kickStream.makeAsyncIterator()
        if await iter.next() != nil {
          return .restartRequested
        }
        return .streamFinished
      }
      let first = await group.next() ?? .streamFinished
      group.cancelAll()
      return first == .streamFinished
    }
  }

  private enum CycleOutcome: Sendable { case streamFinished, restartRequested }

  /// Resets per-filter state. Called once per `ensureSubscription` call
  /// when the filter actually changes.
  func setupForFilter(_ filter: TransactionFilter) {
    loadGeneration &+= 1
    setCurrentFilter(filter)
    pageWindow = 1
    setCurrentTargetInstrument(targetInstrument)
    setTransactions([])
    lastSnapshotPage = nil
    setHasMore(true)
    setError(nil)
    setLoadedCount(0)
    setTotalCount(nil)
    setIsLoading(true)
  }

  /// Receives an emission from `repository.observe(...)`. The observation
  /// page lacks `priorBalance`, so this method calls `repository.fetch(...)`
  /// to obtain the authoritative snapshot before recomputing the running-
  /// balance column.
  private func handleObservedPage(
    _ observed: TransactionPage, filter: TransactionFilter
  ) async {
    guard filter == currentFilter else { return }
    let myGeneration = loadGeneration
    let windowedPageSize = pageSize * pageWindow
    do {
      let fetchStart = ContinuousClock.now
      let snapshot = try await repository.fetch(
        filter: filter, page: 0, pageSize: windowedPageSize)
      let fetchMs = (ContinuousClock.now - fetchStart).inMilliseconds
      guard !Task.isCancelled, myGeneration == loadGeneration,
        filter == currentFilter
      else { return }
      await applySnapshot(
        snapshot, observedCount: observed.transactions.count, fetchMs: fetchMs)
    } catch is CancellationError {
      // View teardown / restart — not user-actionable; matches the
      // pattern in the legacy imperative `fetchPage` path.
      return
    } catch {
      guard myGeneration == loadGeneration, filter == currentFilter else { return }
      logger.error("Failed to load transactions: \(error.localizedDescription)")
      setError(error)
      setIsLoading(false)
      // Wake any `load(filter:)` callers parked on the next emission so
      // a fetch failure surfaces as a returned `load` rather than a
      // hang. The error is observable on `self.error`.
      wakePendingLoadAwaiters()
    }
  }

  func applySnapshot(
    _ snapshot: TransactionPage, observedCount: Int, fetchMs: Int
  ) async {
    await withReactiveStoreSignpost("transaction-store-apply") {
      lastSnapshotPage = snapshot
      setCurrentTargetInstrument(snapshot.targetInstrument)
      setHasMore(snapshot.transactions.count >= pageSize * pageWindow)
      setLoadedCount(snapshot.transactions.count)
      if let total = snapshot.totalCount {
        setTotalCount(total)
      }
      let recomputeStart = ContinuousClock.now
      await recomputeBalances(reason: .freshSnapshot)
      let recomputeMs = (ContinuousClock.now - recomputeStart).inMilliseconds
      setIsLoading(false)
      Self.logFetchPageTiming(
        logger: logger,
        fetchMs: fetchMs,
        recomputeMs: recomputeMs,
        count: observedCount,
        totalLoaded: loadedCount)
      testObservationTickContinuation.yield(())
      wakePendingLoadAwaiters()
    }
  }

  /// Recomputes the running-balance column from the cached
  /// `lastSnapshotPage`. Called by the data path (after `applySnapshot`)
  /// and by the rate-tick path (no DB re-fetch needed — only the
  /// conversion layer is stale).
  func recomputeBalances(reason: RecomputeReason) async {
    guard let snapshot = lastSnapshotPage else { return }
    let result = await TransactionPage.withRunningBalances(
      transactions: snapshot.transactions,
      priorBalance: snapshot.priorBalance,
      accountId: currentFilter.accountId,
      accountIds: currentFilter.accountIds,
      earmarkId: currentFilter.earmarkId,
      targetInstrument: snapshot.targetInstrument,
      conversionService: conversionService)
    if Task.isCancelled { return }
    setTransactions(result.rows)
    if let conversionError = result.firstConversionError {
      logger.error(
        "Conversion failed while computing running balances: \(conversionError.localizedDescription)"
      )
      setError(conversionError)
    } else if error is RunningBalanceConversionError {
      setError(nil)
    }
    if reason == .rateTick {
      testObservationTickContinuation.yield(())
    }
  }

  /// Subscribes to `conversionService.observeRates()` /
  /// `…observeErrors()`. A rate tick recomputes the running-balance
  /// column against the most recent snapshot (no DB re-fetch); an error
  /// tick is surfaced on `self.error`. Spawned from `init`.
  func observeRateChannels() async {
    let rateStream = conversionService.observeRates()
    let rateErrors = conversionService.observeErrors()
    await withTaskGroup(of: Void.self) { group in
      group.addTask { [self] in
        for await _ in rateStream {
          await self.recomputeBalances(reason: .rateTick)
        }
      }
      group.addTask { [self] in
        for await error in rateErrors {
          await self.surface(observationError: error)
        }
      }
    }
  }

  /// Consumes the shared registry's change stream. Each tick re-runs
  /// the imperative reload for the active filter so an instrument-
  /// metadata edit applied to the shared registry (which does not
  /// re-fire the per-profile data observation) live-refreshes the
  /// open list. No-op until a subscription has been started
  /// (`lastSnapshotPage != nil`); the first `load`/`observe` will
  /// fetch fresh data anyway. `Task.isCancelled` is re-checked after
  /// the stream suspension so a teardown that races a tick exits
  /// before issuing a fetch. Strong `self` capture matches
  /// `observeRateChannels()` — the task's lifetime is gated by
  /// `stopObserving()` / `deinit`.
  func observeInstrumentRegistryChanges(
    _ changes: AsyncStream<Void>
  ) async {
    for await _ in changes {
      if Task.isCancelled { return }
      guard lastSnapshotPage != nil else { continue }
      await runImperativeReload(filter: currentFilter)
    }
  }
}
