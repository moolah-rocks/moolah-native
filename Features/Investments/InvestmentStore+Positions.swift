import Foundation

// Position-tracking surface for `InvestmentStore`.
//
// `loadPositions` reads transaction legs for `accountId` and aggregates
// them into per-instrument `Position`s. `valuatePositions` converts
// each position into `profileCurrency` via `conversionService`.
// `refreshPositionTrackedPerformance` computes the lifetime
// `AccountPerformance` summary for the position-tracked path.
extension InvestmentStore {

  /// Load positions for a position-tracked account by computing them from transaction legs.
  func loadPositions(accountId: UUID) async {
    guard let transactionRepository else {
      logger.warning("loadPositions called without transactionRepository")
      return
    }
    do {
      let allTransactions = try await fetchAllAccountTransactions(
        repository: transactionRepository, accountId: accountId)
      guard !Task.isCancelled else { return }
      let quantityByInstrument = sumLegQuantities(
        transactions: allTransactions, accountId: accountId)
      setLoadedAccountId(accountId)
      setPositions(
        quantityByInstrument
          .compactMap { instrument, quantity in
            guard quantity != 0 else { return nil }
            return Position(instrument: instrument, quantity: quantity)
          }
          .sorted { $0.instrument.name < $1.instrument.name })
    } catch is CancellationError {
      return  // Cancelling a `.task` mid-pagination is not a failure.
    } catch {
      logger.error("Failed to load positions: \(error.localizedDescription)")
      setError(error)
    }
  }

  /// Pages through `accountId`'s transactions, exiting early on
  /// cancellation per `guides/CONCURRENCY_GUIDE.md`.
  private func fetchAllAccountTransactions(
    repository: TransactionRepository, accountId: UUID
  ) async throws -> [Transaction] {
    var allTransactions: [Transaction] = []
    var page = 0
    while true {
      let result = try await repository.fetch(
        filter: TransactionFilter(accountId: accountId),
        page: page,
        pageSize: 200)
      try Task.checkCancellation()
      allTransactions.append(contentsOf: result.transactions)
      if result.transactions.count < 200 { break }
      page += 1
    }
    return allTransactions
  }

  /// Sums leg quantities for `accountId` grouped by `Instrument`.
  private func sumLegQuantities(
    transactions: [Transaction], accountId: UUID
  ) -> [Instrument: Decimal] {
    var quantityByInstrument: [Instrument: Decimal] = [:]
    for txn in transactions {
      for leg in txn.legs where leg.accountId == accountId {
        quantityByInstrument[leg.instrument, default: 0] += leg.quantity
      }
    }
    return quantityByInstrument
  }

  /// Valuate all loaded positions using current market prices. Per
  /// Rule 11 in `guides/INSTRUMENT_CONVERSION_GUIDE.md`: a failed
  /// conversion marks the aggregate `totalPortfolioValue` unavailable
  /// and sets `error`; sibling rows still render with their successful
  /// values. `.knownZero` positions drop out of `valuedPositions`
  /// entirely (issue #790).
  func valuatePositions(profileCurrency: Instrument, on date: Date) async {
    // Phase 1 — accumulate one batch request per cross-instrument position;
    // host-currency positions resolve inline (Rule 8 fast path) and never
    // contribute a request. Phase 2 — one batched conversion (cancellation
    // surfaces as a thrown `CancellationError`). Phase 3 — assemble each
    // position's row and fold its outcome into the total / first failure.
    var requests: [BatchConversionRequest] = []
    requests.reserveCapacity(positions.count)
    for position in positions where position.instrument.id != profileCurrency.id {
      requests.append(
        BatchConversionRequest(
          amount: InstrumentAmount(
            quantity: position.quantity, instrument: position.instrument),
          target: profileCurrency,
          date: date))
    }

    let outcomes: [BatchConversionOutcome]
    do {
      outcomes = try await conversionService.convertResultBatch(requests)
    } catch {
      // Cancellation is task-wide and not a failure: leave published state
      // untouched so a re-run recomputes from scratch.
      return
    }

    var valued: [ValuedPosition] = []
    var total: Decimal = 0
    var firstFailure: Error?
    var cursor = 0
    for position in positions {
      let isHostCurrency = position.instrument.id == profileCurrency.id
      let resolved: BatchConversionOutcome? = isHostCurrency ? nil : outcomes[cursor]
      if !isHostCurrency { cursor += 1 }
      let (entry, outcome) = valuate(
        position: position, profileCurrency: profileCurrency, outcome: resolved)
      if let entry { valued.append(entry) }
      switch outcome {
      case .success(let value):
        total += value
      case .knownZero:
        continue
      case .failure(let error):
        if firstFailure == nil { firstFailure = error }
      }
    }

    setValuedPositions(valued)
    if let firstFailure {
      setTotalPortfolioValue(nil)
      setError(firstFailure)
    } else {
      setTotalPortfolioValue(total)
    }
  }

  /// Re-runs `valuatePositions` against the most recently loaded
  /// account. `ProfileSession` calls this from
  /// `CryptoTokenStore.onRegistrationsChanged` so a freshly-marked
  /// `.spam` token drops out of `valuedPositions` without the user
  /// having to navigate away and back. Issue #790.
  func revaluateLoadedPositions() async {
    guard let profileCurrency = loadedHostCurrency else { return }
    await valuatePositions(profileCurrency: profileCurrency, on: Date())
  }

  /// Recompute the position-tracked `accountPerformance` from the loaded
  /// transactions and `valuedPositions`. Called from `loadAllData` and
  /// `reloadPositionsIfNeeded` after a trade is recorded. Sets
  /// `accountPerformance` to `nil` and surfaces the error on conversion
  /// failure; partial sums are not shown.
  func refreshPositionTrackedPerformance(
    accountId: UUID, profileCurrency: Instrument
  ) async {
    guard let transactionRepository else {
      setAccountPerformance(nil)
      return
    }
    do {
      let txns = try await fetchAllTransactions(
        repository: transactionRepository,
        accountId: accountId)
      setAccountPerformance(
        try await AccountPerformanceCalculator.compute(
          accountId: accountId,
          transactions: txns,
          valuedPositions: valuedPositions,
          profileCurrency: profileCurrency,
          conversionService: conversionService))
    } catch is CancellationError {
      return
    } catch {
      logger.warning(
        "AccountPerformance unavailable: \(error.localizedDescription, privacy: .public)"
      )
      setAccountPerformance(nil)
      // self.error intentionally not set — performance tile degrades to
      // "Unavailable" while the rest of the account view stays functional.
    }
  }

  enum ValuationOutcome {
    case success(Decimal)
    /// `.unpriced` / `.spam` crypto source — drop the position from
    /// `valuedPositions`. Issue #790.
    case knownZero
    case failure(Error)
  }

  /// Assemble one position's `ValuedPosition` + `ValuationOutcome` from its
  /// pre-resolved batch `outcome`. Pass `outcome: nil` for a host-currency
  /// position (Rule 8 fast path) — it values 1:1 without a conversion.
  private func valuate(
    position: Position, profileCurrency: Instrument, outcome: BatchConversionOutcome?
  ) -> (ValuedPosition?, ValuationOutcome) {
    guard let outcome else {
      let entry = ValuedPosition(
        instrument: position.instrument,
        quantity: position.quantity,
        unitPrice: nil,
        costBasis: nil,
        value: InstrumentAmount(quantity: position.quantity, instrument: profileCurrency))
      return (entry, .success(position.quantity))
    }
    switch outcome {
    case .knownZero:
      return (nil, .knownZero)
    case .value(let converted):
      let value = converted.quantity
      let unit =
        position.quantity == 0
        ? nil
        : InstrumentAmount(quantity: value / position.quantity, instrument: profileCurrency)
      let entry = ValuedPosition(
        instrument: position.instrument,
        quantity: position.quantity,
        unitPrice: unit,
        costBasis: nil,
        value: converted)
      return (entry, .success(value))
    case .failure(let error):
      logger.warning(
        "Failed to valuate position \(position.instrument.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      let entry = ValuedPosition(
        instrument: position.instrument,
        quantity: position.quantity,
        unitPrice: nil,
        costBasis: nil,
        value: nil)
      return (entry, .failure(error))
    }
  }
}
