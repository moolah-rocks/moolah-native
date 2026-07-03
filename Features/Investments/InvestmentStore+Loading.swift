import Foundation

// Loading + mutation surface for `InvestmentStore`.
//
// `loadValues` and `loadDailyBalances` paginate against the repository
// and write into `values` / `dailyBalances`. `loadAllData` is the
// view-driven entry point that branches on `Account.valuationMode`.
//
// `setValue` / `removeValue` are pass-through writes to the repository;
// the reactive observation in `+Observation.swift` re-emits and updates
// `values` via `applyValuesPage`. Local mutation kept here as well so
// the UI reflects the change synchronously when the active subscription
// hasn't caught up yet.
extension InvestmentStore {

  /// Load all values for the account.
  ///
  /// Per `guides/CONCURRENCY_GUIDE.md`, pagination loops must check
  /// `Task.isCancelled` after each network round-trip so that when the
  /// caller is cancelled (e.g. the `.task` on `InvestmentAccountView`
  /// tears down) we stop paginating immediately rather than fetching
  /// every remaining page and then discarding the result.
  func loadValues(accountId: UUID) async {
    setActiveAccount(accountId)
    do {
      var all: [InvestmentValue] = []
      var page = 0
      let batchSize = pagedValuesPageSize
      while true {
        let result = try await repository.fetchValues(
          accountId: accountId, page: page, pageSize: batchSize)
        guard !Task.isCancelled else { return }
        all.append(contentsOf: result.values)
        if !result.hasMore { break }
        page += 1
      }
      setValues(all)
      yieldTestObservationTick()
    } catch is CancellationError {
      return  // Cancelling a `.task` mid-pagination is not a failure.
    } catch {
      logger.error("Failed to load investment values: \(error.localizedDescription)")
      setError(error)
    }
  }

  /// Loads the legacy account-level cumulative-balance series.
  ///
  /// The repository returns one entry per (date, instrument) tuple so
  /// multi-instrument legacy accounts do not conflate quantities of
  /// different instruments under one label (issue #579). This store
  /// converts each per-instrument balance to `hostCurrency` on its own
  /// date and aggregates by date so the consuming chart sees a single
  /// series in the host currency.
  ///
  /// Per Rule 11 in `guides/INSTRUMENT_CONVERSION_GUIDE.md`: if any
  /// per-instrument conversion fails, the whole series is marked
  /// unavailable (`dailyBalances = []` and `error` set) rather than
  /// rendering a partial sum or a native-instrument fallback.
  func loadDailyBalances(accountId: UUID, hostCurrency: Instrument) async {
    let generation = snapshotGeneration
    do {
      let raw = try await repository.fetchDailyBalances(accountId: accountId)
      let aggregated = try await aggregateDailyBalances(raw: raw, hostCurrency: hostCurrency)
      // Drop a superseded pass so a stale account's series can't overwrite the
      // switched-to account's (#1209).
      guard generation == snapshotGeneration else { return }
      setDailyBalances(aggregated)
    } catch is CancellationError {
      return  // Cancelling a `.task` mid-load is not a failure.
    } catch {
      logger.error("Failed to load daily balances: \(error.localizedDescription)")
      // Don't surface a superseded pass's failure over the fresher account.
      guard generation == snapshotGeneration else { return }
      setError(error)
      setDailyBalances([])
    }
  }

  /// Loads the full dataset required by `InvestmentAccountView`, branching on
  /// the account's `valuationMode`. Keeps the branching logic out of the view
  /// so `.task`/`.refreshable` blocks stay one-liners.
  ///
  /// `setActiveAccount(...)` is only invoked on the `.recordedValue`
  /// branch — the per-account `observeValues(...)` subscription drives
  /// the `values` array, and the trades-mode UI does not read `values`.
  /// Subscribing on the trades branch would populate `values` from any
  /// pre-existing snapshot rows for the account (legacy data, or rows
  /// recorded before the user switched modes), which would confuse
  /// callers that pin "trades-mode means values is empty" semantics.
  func loadAllData(account: Account, profileCurrency: Instrument) async {
    // Authoritative load: supersede any in-flight rate-tick / previous-account
    // pass so its late publish can't clobber this account's data (#1209).
    bumpSnapshotGeneration()
    setLoadedHostCurrency(profileCurrency)
    setAccountPerformance(nil)  // clear stale data immediately
    await refreshAssetKeys()
    switch account.valuationMode {
    case .recordedValue:
      await loadRecordedValueBranch(account: account, profileCurrency: profileCurrency)
    case .calculatedFromTrades:
      await loadTradesBranch(account: account, profileCurrency: profileCurrency)
    }
  }

  private func loadRecordedValueBranch(account: Account, profileCurrency: Instrument) async {
    setActiveAccount(account.id)
    // `loadValues` and `loadDailyBalances` each paginate against the
    // backend (potentially many round-trips on accounts with long
    // history) and write disjoint state (`self.values` vs
    // `self.dailyBalances`). Running them in parallel turns the
    // wall-clock latency from `t(values) + t(balances)` to `max(...)`
    // — measurable on accounts with multi-page history. Both methods
    // are `@MainActor`-isolated, so the actual writes still serialise
    // on the main actor.
    async let loadedValues: Void = loadValues(accountId: account.id)
    async let loadedBalances: Void = loadDailyBalances(
      accountId: account.id, hostCurrency: profileCurrency)
    _ = await (loadedValues, loadedBalances)
    guard !Task.isCancelled else { return }
    setAccountPerformance(
      AccountPerformanceCalculator.computeLegacy(
        dailyBalances: dailyBalances,
        values: values,
        instrument: profileCurrency))
  }

  private func loadTradesBranch(account: Account, profileCurrency: Instrument) async {
    // Trades-mode accounts derive value from `positions`, not from
    // `investment_value` snapshots, so don't subscribe to the per-
    // account values stream. Clear any leftover state from a prior
    // recordedValue load so the views see a clean slate.
    setActiveAccount(nil)
    await loadPositions(accountId: account.id, accountChainId: account.chainId)
    guard !Task.isCancelled else { return }
    await valuatePositions(profileCurrency: profileCurrency, on: Date())
    guard !Task.isCancelled else { return }
    await refreshPositionTrackedPerformance(
      accountId: account.id, profileCurrency: profileCurrency)
  }

  /// Recompute the legacy `accountPerformance` from the in-memory `values`
  /// and `dailyBalances` arrays after a `setValue` / `removeValue`
  /// mutation. Synchronous: the legacy path doesn't need conversion.
  ///
  /// Uses `loadedHostCurrency` to match `loadAllData`'s legacy branch —
  /// `dailyBalances` are always in `loadedHostCurrency` (converted by
  /// `loadDailyBalances`), so callers must not pass a different
  /// instrument. The `.AUD` final fallback only fires if a mutation
  /// happens before `loadAllData` ran, which should not occur in
  /// practice.
  func refreshLegacyPerformance() {
    setAccountPerformance(
      AccountPerformanceCalculator.computeLegacy(
        dailyBalances: dailyBalances,
        values: values,
        instrument: loadedHostCurrency ?? .AUD))
  }

  /// Refreshes position data after a trade is recorded. Used from
  /// `.onChange` where we only care about position-tracked accounts.
  func reloadPositionsIfNeeded(account: Account, profileCurrency: Instrument) async {
    guard account.valuationMode == .calculatedFromTrades else { return }
    // Authoritative reload (post-trade): supersede any in-flight rate-tick pass.
    bumpSnapshotGeneration()
    await loadPositions(accountId: account.id, accountChainId: account.chainId)
    guard !Task.isCancelled else { return }
    await valuatePositions(profileCurrency: profileCurrency, on: Date())
    guard !Task.isCancelled else { return }
    await refreshPositionTrackedPerformance(
      accountId: account.id, profileCurrency: profileCurrency)
  }

  func setValue(accountId: UUID, date: Date, value: InstrumentAmount) async {
    setError(nil)
    let generation = snapshotGeneration
    do {
      try await repository.setValue(accountId: accountId, date: date, value: value)
      // If an account switch bumped the generation during the write, `values`
      // now holds the other account's page — splicing this account's entry in
      // and publishing would corrupt it (#1209). The write persisted; the
      // reactive `applyValuesPage` subscription refreshes the active account.
      guard generation == snapshotGeneration else { return }
      // Otherwise update locally so the UI reflects the change synchronously
      // when the active subscription hasn't caught up yet.
      let newValue = InvestmentValue(date: date, value: value)
      var updated = values
      updated.removeAll { $0.date.isSameDay(as: date) }
      updated.append(newValue)
      updated.sort()
      setValues(updated)
      refreshLegacyPerformance()
    } catch {
      logger.error("Failed to set investment value: \(error.localizedDescription)")
      setError(error)
    }
  }

  func removeValue(accountId: UUID, date: Date) async {
    setError(nil)
    let generation = snapshotGeneration
    do {
      try await repository.removeValue(accountId: accountId, date: date)
      // Skip the local update if an account switch bumped the generation
      // mid-write; see `setValue`.
      guard generation == snapshotGeneration else { return }
      var updated = values
      updated.removeAll { $0.date.isSameDay(as: date) }
      setValues(updated)
      refreshLegacyPerformance()
    } catch {
      logger.error("Failed to remove investment value: \(error.localizedDescription)")
      setError(error)
    }
  }
}
