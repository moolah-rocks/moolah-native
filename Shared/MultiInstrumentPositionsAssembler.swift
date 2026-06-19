import Foundation
import OSLog

/// Store-independent helper that owns the cost-basis-snapshot and history-
/// assembly logic for multi-instrument positions views.
///
/// Call `fetchTransactions(repository:accountIds:)` to load all relevant
/// transactions, then `assemble(context:valuedRows:transactions:range:now:)` to
/// produce the `PositionsViewInput` the view layer needs. Separating fetch
/// from assembly lets callers supply a pre-fetched slice (e.g. a group-level
/// merge) without duplicating the cost-basis engine or history builder.
///
/// Sendable: `conversionService` is an existential protocol; the concrete
/// implementations shipped with the app are all `Sendable`.
struct MultiInstrumentPositionsAssembler: Sendable {
  let conversionService: any InstrumentConversionService
  private let logger = Logger(
    subsystem: "com.moolah.app", category: "MultiInstrumentPositionsAssembler")

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

  /// Open-lot remaining cost per instrument id, in `hostCurrency` `Decimal`s.
  ///
  /// Classifies only the legs that belong to `accountIds` so internal
  /// transfers between group members net out — consistent with how
  /// `PositionsHistoryBuilder` handles the same set. Instruments whose
  /// classification fails are **omitted** (cost unavailable, not zero) per
  /// `guides/INSTRUMENT_CONVERSION_GUIDE.md` Rule 11.
  ///
  /// Throws `CancellationError` via `Task.checkCancellation()` so a cancelled
  /// task never produces a partial cost-basis snapshot.
  func costBasisSnapshot(
    transactions: [Transaction],
    accountIds: Set<UUID>,
    hostCurrency: Instrument
  ) async throws -> [String: Decimal] {
    var engine = CostBasisEngine()
    var instrumentsWithFailedClassification: Set<String> = []
    let sorted = transactions.sorted { $0.date < $1.date }
    for txn in sorted {
      try Task.checkCancellation()
      let scopedLegs = txn.legs.filter {
        $0.accountId.map { accountIds.contains($0) } ?? false
      }
      guard !scopedLegs.isEmpty else { continue }
      do {
        let classification = try await TradeEventClassifier.classify(
          legs: scopedLegs,
          on: txn.date,
          hostCurrency: hostCurrency,
          conversionService: conversionService
        )
        for buy in classification.buys {
          engine.processBuy(
            instrument: buy.instrument,
            quantity: buy.quantity,
            costPerUnit: buy.costPerUnit,
            date: txn.date)
        }
        for sell in classification.sells {
          _ = engine.processSell(
            instrument: sell.instrument,
            quantity: sell.quantity,
            proceedsPerUnit: sell.proceedsPerUnit,
            date: txn.date)
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        logger.warning(
          "Failed to classify txn \(txn.id, privacy: .public) for cost basis: \(error.localizedDescription, privacy: .public)"
        )
        for leg in scopedLegs where leg.instrument.kind != .fiatCurrency {
          instrumentsWithFailedClassification.insert(leg.instrument.id)
        }
      }
    }
    var result: [String: Decimal] = [:]
    for lot in engine.allOpenLots() {
      result[lot.instrument.id, default: 0] += lot.remainingCost
    }
    for id in instrumentsWithFailedClassification {
      result.removeValue(forKey: id)
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
  /// The cost-basis snapshot and the history series are computed concurrently
  /// (they are independent of each other). If the snapshot is cancelled, the
  /// method returns a minimal input with `historicalValue: nil` rather than
  /// propagating the cancellation — the history series result is still valid.
  func assemble(
    context: PositionsAssemblyContext,
    valuedRows: [ValuedPosition],
    transactions: [Transaction],
    range: PositionsTimeRange,
    now: Date = Date()
  ) async -> PositionsViewInput {
    async let snapshotTask = costBasisSnapshot(
      transactions: transactions,
      accountIds: context.accountIds,
      hostCurrency: context.hostCurrency)
    let series = await PositionsHistoryBuilder(conversionService: conversionService).build(
      transactions: transactions,
      accountIds: context.accountIds,
      hostCurrency: context.hostCurrency,
      range: range,
      now: now)
    let costSnapshot: [String: Decimal]
    do {
      costSnapshot = try await snapshotTask
    } catch {
      return PositionsViewInput(
        title: context.title,
        hostCurrency: context.hostCurrency,
        positions: valuedRows,
        historicalValue: nil,
        assetKeysByInstrumentId: context.assetKeysByInstrumentId,
        performance: context.performance,
        alwaysShowsFullSurface: context.alwaysShowsFullSurface)
    }
    let rowsWithCost = valuedRows.map { row in
      ValuedPosition(
        instrument: row.instrument,
        quantity: row.quantity,
        unitPrice: row.unitPrice,
        costBasis: costSnapshot[row.instrument.id].map {
          InstrumentAmount(quantity: $0, instrument: context.hostCurrency)
        },
        value: row.value)
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
}
