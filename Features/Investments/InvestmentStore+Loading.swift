import Foundation

// Loading + mutation surface for `InvestmentStore`.
//
// `loadValues` and `loadDailyBalances` paginate against the repository
// and write into `values` / `dailyBalances`. `loadAllData` is the
// position-derived view entry point.
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
  /// caller is cancelled (e.g. its owning detail task tears down) we stop
  /// paginating immediately rather than fetching
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

  /// Loads the position-derived dataset for an investment account. Legacy
  /// valuation snapshots are deliberately not read.
  func loadAllData(account: Account, profileCurrency: Instrument) async {
    // Authoritative load: supersede any in-flight rate-tick / previous-account
    // pass so its late publish can't clobber this account's data (#1209).
    bumpSnapshotGeneration()
    setLoadedHostCurrency(profileCurrency)
    setAccountPerformance(nil)  // clear stale data immediately
    await refreshAssetKeys()
    setActiveAccount(nil)
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
    } catch {
      logger.error("Failed to remove investment value: \(error.localizedDescription)")
      setError(error)
    }
  }
}
