import Foundation

// Reactive observation pipeline for `AccountStore`.
//
// Three independent surfaces feed `AccountStore`:
//   1. `repository.observeAll()` / `observeErrors()` — the accounts
//      stream that drives `apply(accounts:)`.
//   2. `conversionService.observeRates()` / `observeErrors()` — rate
//      ticks that drive a balance recompute (no DB re-fetch needed).
//   3. `investmentRepository.observeAllValues()` / `observeErrors()` —
//      a tick stream over the `investment_value` table that drives a
//      cache refresh + recompute.
//
// A fourth surface, the shared instrument registry's
// `observeChanges()` stream, is owned by `instrumentChangeObservationTask`
// (spawned from `init`) and drained by `observeInstrumentRegistryChanges`
// below — kept separate from the always-on `TaskGroup` for the same
// reason as the other stores.
extension AccountStore {

  /// Subscribes to every reactive stream in parallel via a `TaskGroup`.
  /// The child tasks run nonisolated; each per-emission body awaits a
  /// `@MainActor`-isolated method on `self` so state assignments happen
  /// on the main actor. Capturing the streams locally (instead of
  /// `self.repository.observeAll()` inside the `addTask` closure) lets
  /// the region-based isolation checker reason about Sendable-ness.
  func observe() async {
    let accountsStream = repository.observeAll()
    let accountErrors = repository.observeErrors()
    let rateStream = conversionService.observeRates()
    let rateErrors = conversionService.observeErrors()
    let investmentValuesTick = investmentRepository?.observeAllValues()
    let investmentErrors = investmentRepository?.observeErrors()
    await withTaskGroup(of: Void.self) { group in
      addCoreObservationTasks(
        to: &group,
        accountsStream: accountsStream,
        accountErrors: accountErrors,
        rateStream: rateStream,
        rateErrors: rateErrors)
      addInvestmentObservationTasks(
        to: &group,
        valuesTick: investmentValuesTick,
        errors: investmentErrors)
      // Cancellation of `observationTask` cancels the group; the
      // `for await` loops exit; the group returns naturally.
    }
  }

  /// Wires the four always-on subscriptions into `group`. Pulled out so
  /// the `observe()` body fits inside SwiftLint's closure body length.
  private func addCoreObservationTasks(
    to group: inout TaskGroup<Void>,
    accountsStream: AsyncStream<[Account]>,
    accountErrors: AsyncStream<any Error>,
    rateStream: AsyncStream<Void>,
    rateErrors: AsyncStream<any Error>
  ) {
    group.addTask { [self] in
      for await fresh in accountsStream { await self.applyAccountsSnapshot(fresh) }
    }
    group.addTask { [self] in
      for await error in accountErrors { await self.surfaceObservationError(error) }
    }
    group.addTask { [self] in
      for await _ in rateStream { await self.recomputeForRateTick() }
    }
    group.addTask { [self] in
      for await error in rateErrors { await self.surfaceObservationError(error) }
    }
  }

  /// Wires the optional investment-repository subscriptions into `group`.
  /// `nil` streams (no investment repository configured — preview /
  /// degraded launches) are simply skipped.
  private func addInvestmentObservationTasks(
    to group: inout TaskGroup<Void>,
    valuesTick: AsyncStream<Void>?,
    errors: AsyncStream<any Error>?
  ) {
    if let valuesTick {
      group.addTask { [self] in
        for await _ in valuesTick { await self.refreshInvestmentValuesAndRecompute() }
      }
    }
    if let errors {
      group.addTask { [self] in
        for await error in errors { await self.surfaceObservationError(error) }
      }
    }
  }

  /// Consumes the shared instrument registry's change stream. Each tick
  /// re-fetches the accounts list and re-applies it so an instrument-
  /// metadata edit applied to the shared registry (which does not
  /// re-fire `repository.observeAll()` — the accounts observation no
  /// longer tracks the `instrument` table) live-refreshes the sidebar.
  /// `Task.isCancelled` is re-checked after the stream suspension so a
  /// teardown that races a tick exits before issuing a fetch. The
  /// task's lifetime is gated by `stopObserving()` / `deinit`, matching
  /// `observe()`.
  ///
  /// `snapshotGeneration` is captured *before* the `fetchAll()` so the
  /// apply can be dropped if a fresher authoritative snapshot lands
  /// while the fetch is in flight — see `applyInstrumentRegistryRefresh`.
  func observeInstrumentRegistryChanges(_ changes: AsyncStream<Void>) async {
    for await _ in changes {
      guard !Task.isCancelled else { return }
      let observedGeneration = snapshotGeneration
      do {
        let fresh = try await repository.fetchAll()
        guard !Task.isCancelled else { return }
        await applyInstrumentRegistryRefresh(fresh, observedGeneration: observedGeneration)
      } catch {
        surfaceObservationError(error)
      }
    }
  }

  // MARK: - Entry-point shims

  /// Per-emission entry point invoked by the `accounts` subscription
  /// driver above. This is the **authoritative** snapshot source: it bumps
  /// `snapshotGeneration` so a concurrent instrument-registry refetch can
  /// detect that it raced a fresher snapshot.
  private func applyAccountsSnapshot(_ fresh: [Account]) async {
    bumpSnapshotGeneration()
    await apply(accounts: fresh)
  }

  /// Applies an instrument-registry-triggered refetch, but only if no
  /// authoritative `observeAll()` snapshot has landed since the fetch was
  /// issued. The `fetchAll()` in `observeInstrumentRegistryChanges` runs
  /// unordered with respect to `observeAll()`; if it read the database
  /// before a concurrent write committed, its row set is stale. Applying
  /// it after a fresher authoritative snapshot would clobber `accounts`
  /// back to a pre-write state. The generation check and the assignment
  /// inside `apply(accounts:)` run with no intervening suspension on the
  /// main actor, so an authoritative snapshot cannot interleave between
  /// the guard and the write — the only harmful ordering (stale refresh
  /// applied *after* a fresh snapshot) is exactly the case the guard
  /// drops. A refresh that lands *before* the next authoritative snapshot
  /// is harmless: the authoritative apply overwrites it.
  ///
  /// Internal (not `private`) so the store's sync-refresh tests can drive
  /// the guard path directly with a captured generation.
  func applyInstrumentRegistryRefresh(
    _ fresh: [Account], observedGeneration: UInt64
  ) async {
    guard snapshotGeneration == observedGeneration else { return }
    await apply(accounts: fresh)
  }

  /// Per-emission entry point for the rate-tick subscription.
  func recomputeForRateTick() async {
    await recomputeConvertedTotals()
  }

  /// Re-hydrate `investmentValueCache` from the repository and trigger
  /// a balance recompute. Driven by `investmentRepository.observeAllValues()`
  /// so a sync-driven write to `investment_value` reaches this store
  /// without the cross-store callback path.
  func refreshInvestmentValuesAndRecompute() async {
    await preloadInvestmentValues()
    await recomputeConvertedTotals()
  }

  /// Asks `investmentValueCache` to hydrate itself with the latest value for
  /// every investment account. Without this, `displayBalance` falls back to
  /// summing positions until `InvestmentStore` happens to call
  /// `updateInvestmentValue(accountId:value:)`, so the sidebar flashes the
  /// transaction sum until the user opens an investment account. See
  /// `InvestmentValueCache.preload(for:)` for the failure-tolerant details.
  func preloadInvestmentValues() async {
    // Only `recordedValue` investment accounts read from the snapshot cache;
    // `calculatedFromTrades` accounts derive their value from positions, so
    // their snapshot fetch would be a wasted round-trip.
    let investmentAccountIds = accounts.ordered
      .filter { $0.type == .investment && $0.valuationMode == .recordedValue }
      .map(\.id)
    await investmentValueCache.preload(for: investmentAccountIds)
  }

  /// Updates the investment value for a specific account locally.
  /// Called when `InvestmentStore` sets or removes a value.
  func updateInvestmentValue(accountId: UUID, value: InstrumentAmount?) async {
    guard accounts.by(id: accountId) != nil else { return }
    investmentValueCache.set(value, for: accountId)
    await recomputeConvertedTotals()
  }

  /// Surface an observation error onto `self.error`.
  func surfaceObservationError(_ error: any Error) {
    surface(error: error)
  }
}
