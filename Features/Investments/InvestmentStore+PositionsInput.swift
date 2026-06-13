// swiftlint:disable multiline_arguments
//
// positionsViewInput and costBasisSnapshot construct multi-argument
// types across multiple lines for readability; the rule fires on every
// such call site in this file.

import Foundation

// `PositionsViewInput` assembly + trade-based cost-basis snapshotting
// for `InvestmentStore`.
extension InvestmentStore {
  // MARK: - PositionsView Input

  /// Coordinates the two-step "load then build positions input" sequence
  /// that the `InvestmentAccountView` runs from its `.task` and
  /// `.refreshable` modifiers, keeping the view bodies free of
  /// multi-step async coordination.
  ///
  /// Errors from `positionsViewInput` propagate; `loadAllData` swallows
  /// its own errors into `self.error` so it never throws here.
  func loadAndBuildPositionsInput(
    account: Account,
    profileCurrency: Instrument,
    range: PositionsTimeRange
  ) async throws -> PositionsViewInput {
    await loadAllData(account: account, profileCurrency: profileCurrency)
    return try await positionsViewInput(title: account.name, range: range)
  }

  /// Builds the `PositionsViewInput` for the unified positions UI. Reads
  /// from the already-loaded `valuedPositions` for the row data, replays
  /// trade transactions through the shared `TradeEventClassifier` +
  /// `CostBasisEngine` to derive a per-instrument cost-basis snapshot, and
  /// asks `PositionsHistoryBuilder` for the chart series.
  ///
  /// Caller-supplied `title` lets the host pass the account name (or any
  /// embedding-appropriate label).
  func positionsViewInput(
    title: String,
    range: PositionsTimeRange
  ) async throws -> PositionsViewInput {
    guard let transactionRepository else {
      let hostCurrency = loadedHostCurrency ?? .AUD
      return PositionsViewInput(
        title: title,
        hostCurrency: hostCurrency,
        positions: valuedPositions,
        historicalValue: nil,
        performance: accountPerformance,
        alwaysShowsFullSurface: true)
    }

    let txns: [Transaction]
    do {
      txns = try await fetchAllTransactions(
        repository: transactionRepository,
        accountId: loadedAccountId ?? UUID())
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      logger.warning(
        "fetchAllTransactions failed, cost basis will be empty: \(error.localizedDescription, privacy: .public)"
      )
      txns = []
    }
    let hostCurrency = loadedHostCurrency ?? valuedPositions.first?.value?.instrument ?? .AUD
    let costSnapshot = await costBasisSnapshot(
      transactions: txns, hostCurrency: hostCurrency)
    let rowsWithCost = applyingCostBasis(costSnapshot, hostCurrency: hostCurrency)

    let series = await PositionsHistoryBuilder(conversionService: conversionService).build(
      transactions: txns,
      accountId: loadedAccountId ?? UUID(),
      hostCurrency: hostCurrency,
      range: range
    )

    return PositionsViewInput(
      title: title,
      hostCurrency: hostCurrency,
      positions: rowsWithCost,
      historicalValue: series,
      assetKeysByInstrumentId: assetKeysByInstrumentId,
      performance: accountPerformance,
      hasAnyHistoricalActivity: Self.hasAnyTradeLeg(
        in: txns, accountId: loadedAccountId, hostCurrency: hostCurrency),
      alwaysShowsFullSurface: true)
  }

  /// Overlays a per-instrument cost-basis snapshot onto the already-loaded
  /// `valuedPositions`, leaving quantity / unit price / value untouched.
  /// An instrument absent from `costSnapshot` keeps a `nil` cost basis
  /// (cost unavailable, not zero — see `costBasisSnapshot`).
  func applyingCostBasis(
    _ costSnapshot: [String: Decimal], hostCurrency: Instrument
  ) -> [ValuedPosition] {
    valuedPositions.map { row in
      ValuedPosition(
        instrument: row.instrument,
        quantity: row.quantity,
        unitPrice: row.unitPrice,
        costBasis: costSnapshot[row.instrument.id].map {
          InstrumentAmount(quantity: $0, instrument: hostCurrency)
        },
        value: row.value
      )
    }
  }

  /// Range-independent "did this account ever hold a non-host-currency
  /// position" check used to keep the chart populated on accounts whose
  /// last trade pre-dates the active range.
  static func hasAnyTradeLeg(
    in transactions: [Transaction], accountId: UUID?, hostCurrency: Instrument
  ) -> Bool {
    transactions.contains { txn in
      txn.legs.contains { leg in
        leg.accountId == accountId
          && leg.type == .trade
          && leg.instrument != hostCurrency
      }
    }
  }

  func fetchAllTransactions(
    repository: TransactionRepository,
    accountId: UUID
  ) async throws -> [Transaction] {
    var all: [Transaction] = []
    var page = 0
    while true {
      let result = try await repository.fetch(
        filter: TransactionFilter(accountId: accountId),
        page: page, pageSize: 200
      )
      try Task.checkCancellation()
      all.append(contentsOf: result.transactions)
      if result.transactions.count < 200 { break }
      page += 1
    }
    return all
  }

  func costBasisSnapshot(
    transactions: [Transaction], hostCurrency: Instrument
  ) async -> [String: Decimal] {
    var engine = CostBasisEngine()
    // Track instruments whose cost basis has been corrupted by a failing
    // classification (e.g., a historical exchange rate gap on a swap). Per
    // Rule 11 we must NOT return a silently-wrong number for these — omit
    // them from the result so the caller treats the cost basis as
    // unavailable rather than wrong.
    var instrumentsWithFailedClassification: Set<String> = []
    let sorted = transactions.sorted { $0.date < $1.date }
    for txn in sorted {
      guard !Task.isCancelled else { break }
      do {
        let classification = try await TradeEventClassifier.classify(
          legs: txn.legs, on: txn.date,
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
        // Mark every non-fiat instrument in this txn's legs as having
        // uncertain cost basis going forward.
        for leg in txn.legs where leg.instrument.kind != .fiatCurrency {
          instrumentsWithFailedClassification.insert(leg.instrument.id)
        }
      }
    }
    var result: [String: Decimal] = [:]
    for lot in engine.allOpenLots() {
      result[lot.instrument.id, default: 0] += lot.remainingCost
    }
    // Drop any instrument whose cost basis is no longer reliable.
    for id in instrumentsWithFailedClassification {
      result.removeValue(forKey: id)
    }
    return result
  }
}
