import Foundation

// Public load / observe entry points for `TransactionStore`. These are the
// thin wrappers views and tests call to drive the observation pipeline in
// `+Observation.swift`.
extension TransactionStore {
  /// View-driven entry point: subscribe to remote changes for `filter` and
  /// stream emissions into `transactions` until the surrounding `.task`
  /// is cancelled. Callers use `.task(id: filter) {
  /// await store.observe(filter: filter) }` — the `for await` loop lives
  /// here, keeping the view thin (per `CLAUDE.md`).
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

  /// Parks the caller until the next `applySnapshot` wakes pending awaiters.
  /// Used by `loadMore()` and by `awaitPublish(throughGeneration:filter:)` in
  /// `+Observation.swift`, so both the page-expansion and imperative-reload
  /// paths can wait deterministically for the next publish. A cancellation
  /// handler wakes the awaiters so a `load(filter:)` whose `.task` was
  /// cancelled mid-park exits promptly instead of lingering until the next
  /// emission; every waiter re-checks `Task.isCancelled` when woken.
  func awaitNextLoadEmissionInternal() async {
    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        pendingLoadAwaiters.append(continuation)
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.wakePendingLoadAwaiters() }
    }
  }
}
