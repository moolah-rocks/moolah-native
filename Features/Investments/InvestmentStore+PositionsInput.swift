import Foundation

// `PositionsViewInput` assembly + trade-based cost-basis snapshotting
// for `InvestmentStore`.
extension InvestmentStore {
  // MARK: - Positions Input

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

    let accountId = loadedAccountId ?? UUID()
    let assembler = MultiInstrumentPositionsAssembler(conversionService: conversionService)

    let txns: [Transaction]
    do {
      txns = try await assembler.fetchTransactions(
        repository: transactionRepository,
        accountIds: [accountId])
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      logger.warning(
        "fetchTransactions failed, cost basis will be empty: \(error.localizedDescription, privacy: .public)"
      )
      txns = []
    }

    let hostCurrency = loadedHostCurrency ?? valuedPositions.first?.value?.instrument ?? .AUD
    let context = PositionsAssemblyContext(
      title: title,
      hostCurrency: hostCurrency,
      accountIds: [accountId],
      assetKeysByInstrumentId: assetKeysByInstrumentId,
      performance: accountPerformance,
      alwaysShowsFullSurface: true)
    return await assembler.assemble(
      context: context,
      valuedRows: valuedPositions,
      transactions: txns,
      range: range)
  }

  // MARK: - Convenience fetch

  /// Single-account convenience that delegates to
  /// `MultiInstrumentPositionsAssembler.fetchTransactions(repository:accountIds:)`.
  /// Used by `refreshPositionTrackedPerformance` in
  /// `InvestmentStore+Positions.swift`, which supplies a single `UUID`.
  func fetchAllTransactions(
    repository: TransactionRepository,
    accountId: UUID
  ) async throws -> [Transaction] {
    let assembler = MultiInstrumentPositionsAssembler(conversionService: conversionService)
    return try await assembler.fetchTransactions(
      repository: repository,
      accountIds: [accountId])
  }
}
