// swiftlint:disable multiline_arguments
//
// `costBasisSnapshot` passes enough labelled parameters to trigger
// multiline_arguments; scoped to this file rather than reformatting
// every call site.

import Foundation
import OSLog

/// The fixed "who / where / how" inputs to `MultiInstrumentPositionsAssembler
/// .assemble(context:valuedRows:transactions:range:)`. Grouping them lets the
/// call site stay below SwiftLint's five-parameter limit while keeping
/// every field named and documented.
struct PositionsAssemblyContext: Sendable {
  /// Display label passed through to `PositionsViewInput.title`.
  let title: String
  /// The host (reporting) currency for all monetary outputs.
  let hostCurrency: Instrument
  /// The account UUIDs whose legs drive cost-basis classification and
  /// history-builder netting.
  let accountIds: Set<UUID>
  /// Maps instrument id → canonical asset key for cross-chain rollup.
  /// Empty (the default) means no rollup — each position stands alone.
  let assetKeysByInstrumentId: [String: String]
  /// Account-level performance numbers, if available. Non-nil triggers the
  /// three-tile performance strip in `PositionsView`.
  let performance: AccountPerformance?
  /// `true` for investment-account hosts, where the full surface renders
  /// even with no open positions. Other callers pass `false` (the default).
  let alwaysShowsFullSurface: Bool

  init(
    title: String,
    hostCurrency: Instrument,
    accountIds: Set<UUID>,
    assetKeysByInstrumentId: [String: String] = [:],
    performance: AccountPerformance? = nil,
    alwaysShowsFullSurface: Bool = false
  ) {
    self.title = title
    self.hostCurrency = hostCurrency
    self.accountIds = accountIds
    self.assetKeysByInstrumentId = assetKeysByInstrumentId
    self.performance = performance
    self.alwaysShowsFullSurface = alwaysShowsFullSurface
  }
}

/// Store-independent helper that owns the cost-basis-snapshot and history-
/// assembly logic for multi-instrument positions views.
///
/// Call `fetchTransactions(repository:accountIds:)` to load all relevant
/// transactions, then `assemble(context:valuedRows:transactions:range:)` to
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
        page: page, pageSize: 200
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
  func costBasisSnapshot(
    transactions: [Transaction],
    accountIds: Set<UUID>,
    hostCurrency: Instrument
  ) async -> [String: Decimal] {
    var engine = CostBasisEngine()
    var instrumentsWithFailedClassification: Set<String> = []
    let sorted = transactions.sorted { $0.date < $1.date }
    for txn in sorted {
      guard !Task.isCancelled else { break }
      let scopedLegs = txn.legs.filter {
        $0.accountId.map { accountIds.contains($0) } ?? false
      }
      guard !scopedLegs.isEmpty else { continue }
      do {
        let classification = try await TradeEventClassifier.classify(
          legs: scopedLegs, on: txn.date,
          hostCurrency: hostCurrency, conversionService: conversionService
        )
        for buy in classification.buys {
          engine.processBuy(
            instrument: buy.instrument, quantity: buy.quantity,
            costPerUnit: buy.costPerUnit, date: txn.date)
        }
        for sell in classification.sells {
          _ = engine.processSell(
            instrument: sell.instrument, quantity: sell.quantity,
            proceedsPerUnit: sell.proceedsPerUnit, date: txn.date)
        }
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
  func assemble(
    context: PositionsAssemblyContext,
    valuedRows: [ValuedPosition],
    transactions: [Transaction],
    range: PositionsTimeRange
  ) async -> PositionsViewInput {
    let costSnapshot = await costBasisSnapshot(
      transactions: transactions,
      accountIds: context.accountIds,
      hostCurrency: context.hostCurrency)
    let rowsWithCost = valuedRows.map { row in
      ValuedPosition(
        instrument: row.instrument, quantity: row.quantity, unitPrice: row.unitPrice,
        costBasis: costSnapshot[row.instrument.id].map {
          InstrumentAmount(quantity: $0, instrument: context.hostCurrency)
        },
        value: row.value)
    }
    let series = await PositionsHistoryBuilder(conversionService: conversionService).build(
      transactions: transactions, accountIds: context.accountIds,
      hostCurrency: context.hostCurrency, range: range)
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
