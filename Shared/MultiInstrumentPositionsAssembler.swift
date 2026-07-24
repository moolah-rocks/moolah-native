import Foundation

/// Store-independent helper that owns the cost-basis-snapshot and history-
/// assembly logic for multi-instrument positions views.
///
/// Call `fetchTransactions(repository:accountIds:)` to load all relevant
/// transactions, then
/// `assemble(context:valuedRows:transactions:range:ledger:now:)` to produce
/// the `PositionsViewInput` the view layer needs. The `ledger` is the shared
/// profile-wide `HoldingsCostLedger` (built once per data load by
/// `HoldingsCostLedgerStore` and passed in) — the assembler never builds its
/// own, because a per-view build over the viewed subset cannot see a
/// transfer's source-account lots. Separating fetch from assembly lets callers
/// supply a pre-fetched slice (e.g. a group-level merge) without duplicating
/// the history builder.
///
/// Sendable: `conversionService` is an existential protocol; the concrete
/// implementations shipped with the app are all `Sendable`.
struct MultiInstrumentPositionsAssembler: Sendable {
  let conversionService: any InstrumentConversionService

  // MARK: - Transaction fetch

  /// Pages through all transactions touching any of `accountIds`.
  func fetchTransactions(
    repository: any TransactionRepository,
    accountIds: Set<UUID>
  ) async throws -> [Transaction] {
    var all: [Transaction] = []
    var page = 0
    while true {
      let result = try await repository.fetch(
        filter: TransactionFilter(accountIds: accountIds),
        page: page,
        pageSize: 200
      )
      try Task.checkCancellation()
      all.append(contentsOf: result.transactions)
      if result.transactions.count < 200 { break }
      page += 1
    }
    return all
  }

  // MARK: - Cost-basis snapshot

  /// Remaining amount invested per instrument id (in the profile / reference
  /// currency `Decimal`s), read from the shared profile-wide
  /// `HoldingsCostLedger` — the SAME source the chart baseline now uses, so
  /// the positions table and the chart cannot disagree. A tracked→tracked
  /// transfer-in holding therefore shows its carried-over invested (from the
  /// source account's lots via `moveLots`), not a per-view-reacquired value.
  ///
  /// For each `instrument`, the cost is
  /// `ledger.remainingInvested(accountIds:instrument:onOrBefore: asOfDate)`.
  /// An instrument whose `(account, instrument)` key is unavailable (Rule 11 —
  /// a genuine conversion failure in the ledger build), or the whole ledger
  /// being unavailable (`nil` — a genuine provider failure), yields **no
  /// entry** for that instrument → the caller renders its cost as unavailable
  /// (`nil` `costBasis`), never `0`. Pure and non-throwing: it only queries the
  /// already-built ledger's change-points, running no conversions.
  func costBasisSnapshot(
    ledger: HoldingsCostLedger?,
    accountIds: Set<UUID>,
    instruments: [Instrument],
    asOfDate: Date
  ) -> [String: Decimal] {
    guard let ledger else { return [:] }
    var result: [String: Decimal] = [:]
    for instrument in instruments {
      guard
        let cost = ledger.remainingInvested(
          accountIds: accountIds, instrument: instrument, onOrBefore: asOfDate)
      else { continue }  // unavailable → omit (Rule 11), never 0
      result[instrument.id] = cost
    }
    return result
  }

  // MARK: - Full input assembly

  /// Builds the full `PositionsViewInput`: overlays cost basis on `valuedRows`,
  /// builds the history series, and sets `hasAnyHistoricalActivity`.
  ///
  /// **Invariant (caller's responsibility):** every non-nil
  /// `valuedRows[i].value.instrument` must equal `context.hostCurrency`. The
  /// four production call sites guarantee this via `PositionsValuator`; no
  /// runtime assertion is added here to avoid trapping in production on
  /// unexpected data.
  ///
  /// The cost-basis snapshot is a pure ledger query (no conversions) and the
  /// history series is built by `PositionsHistoryBuilder`; both read the same
  /// shared `ledger`, so the table cost and the chart baseline cannot disagree.
  /// The builder handles its own cancellation internally (returning a partial
  /// series); the caller drops the whole result if its task was cancelled.
  func assemble(
    context: PositionsAssemblyContext,
    valuedRows: [ValuedPosition],
    transactions: [Transaction],
    range: PositionsTimeRange,
    ledger: HoldingsCostLedger?,
    now: Date = Date()
  ) async -> PositionsViewInput {
    let series = await PositionsHistoryBuilder(conversionService: conversionService).build(
      transactions: transactions,
      accountIds: context.accountIds,
      hostCurrency: context.hostCurrency,
      range: range,
      ledger: ledger,
      now: now)
    let costSnapshot = costBasisSnapshot(
      ledger: ledger,
      accountIds: context.accountIds,
      instruments: valuedRows.map(\.instrument),
      asOfDate: now)
    let rowsWithCost = valuedRows.map { row in
      ValuedPosition(
        instrument: row.instrument,
        quantity: row.quantity,
        unitPrice: row.unitPrice,
        costBasis: costSnapshot[row.instrument.id].map {
          InstrumentAmount(quantity: $0, instrument: context.hostCurrency)
        },
        value: row.value,
        // Preserve the owning chain the upstream valuator stamped; this
        // overlay only adds cost basis and must not drop chain identity.
        accountChainId: row.accountChainId,
        // Price provenance is also produced upstream by the valuator. The
        // cost-basis overlay must keep it so the aggregate header can disclose
        // the oldest effective daily input used by the visible rows.
        oldestPriceDate: row.oldestPriceDate)
    }
    return PositionsViewInput(
      title: context.title,
      hostCurrency: context.hostCurrency,
      positions: rowsWithCost,
      historicalValue: series,
      assetKeysByInstrumentId: context.assetKeysByInstrumentId,
      performance: context.performance,
      hasAnyHistoricalActivity: Self.hasAnyTradeLeg(
        in: transactions,
        accountIds: context.accountIds,
        hostCurrency: context.hostCurrency),
      alwaysShowsFullSurface: context.alwaysShowsFullSurface)
  }

  // MARK: - Trade-leg check

  /// Range-independent check: `true` iff any transaction in `transactions`
  /// contains a `.trade` leg in a non-`hostCurrency` instrument belonging to
  /// one of the given `accountIds`.
  static func hasAnyTradeLeg(
    in transactions: [Transaction],
    accountIds: Set<UUID>,
    hostCurrency: Instrument
  ) -> Bool {
    transactions.contains { txn in
      txn.legs.contains { leg in
        (leg.accountId.map { accountIds.contains($0) } ?? false)
          && leg.type == .trade
          && leg.instrument != hostCurrency
      }
    }
  }

  /// Whether the account-detail surface needs the profile-wide holdings
  /// ledger. Fiat-only accounts render a value history without cost-basis
  /// work; investment surfaces, current non-host holdings, and historical
  /// non-host trades require the ledger for cost, invested baselines, and
  /// performance.
  static func requiresHoldingsLedger(
    alwaysShowsFullSurface: Bool,
    valuedRows: [ValuedPosition],
    transactions: [Transaction],
    accountIds: Set<UUID>,
    hostCurrency: Instrument
  ) -> Bool {
    alwaysShowsFullSurface
      || AccountDetailLayout.showsPerformanceTiles(
        valuedRows: valuedRows, hostCurrency: hostCurrency)
      || hasAnyTradeLeg(
        in: transactions, accountIds: accountIds, hostCurrency: hostCurrency)
  }
}
