import Foundation

// MARK: - Snapshot / context assembly (main actor)

extension InsightStore {
  /// Gathers the main-actor half of `InsightInput` from the sibling stores.
  func makeSnapshot() -> InsightInputSnapshot {
    InsightInputSnapshot(
      monthly: sources.analysis.incomeAndExpense,
      expenseBreakdown: sources.analysis.expenseBreakdown,
      dailyBalances: sources.analysis.dailyBalances,
      earmarks: makeEarmarkSnapshots(),
      profitLoss: sources.reporting.profitLoss,
      // Gate: while the cross-chain identity migration is in flight, lots for
      // the same asset may be split across retired + canonical instrument ids.
      // Pass an empty array so no capital-gains insight is generated from
      // mixed-id lots.
      capitalGains: sources.reporting.isMigratingCrossChainIdentity
        ? [] : (sources.reporting.capitalGainsResult?.events ?? []),
      categories: sources.category.categories,
      accountGroups: (sources.accountGroup?.groups ?? []).map {
        InsightAccountGroup(id: $0.id, name: $0.name)
      },
      accountGroupMembership: makeAccountGroupMembership())
  }

  func makeContext() -> InsightContext {
    InsightContext(
      now: Date(),
      reportingCurrency: reportingInstrument,
      financialMonthEnd: sources.analysis.monthEnd)
  }

  /// `accountId → groupId` map for every grouped account.
  private func makeAccountGroupMembership() -> [UUID: UUID] {
    var membership: [UUID: UUID] = [:]
    for account in sources.account.accounts.ordered {
      if let groupId = account.groupId {
        membership[account.id] = groupId
      }
    }
    return membership
  }

  /// Joins each same-reporting-currency `Earmark` with its converted balances
  /// from `EarmarkStore`.
  ///
  /// Foreign-instrument earmarks are intentionally omitted (Rule 11 — never
  /// mislabel native-instrument amounts as reporting currency): the dicts in
  /// `EarmarkStore` are in each earmark's **own** instrument, not the reporting
  /// instrument, so including them would mix instruments and risk a trap. This
  /// is the deliberate, documented degradation until `EarmarkStore` exposes
  /// per-earmark reporting-currency totals.
  ///
  /// Remaining deliberate degradation:
  /// - `budget: nil` — the per-earmark budget total is not yet reduced to the
  ///   reporting currency, so it is omitted rather than guessed.
  private func makeEarmarkSnapshots() -> [EarmarkSnapshot] {
    let zero = InstrumentAmount.zero(instrument: reportingInstrument)
    return sources.earmark.earmarks.compactMap { earmark in
      guard earmark.instrument == reportingInstrument else { return nil }
      return EarmarkSnapshot(
        id: earmark.id,
        name: earmark.name,
        balance: sources.earmark.convertedBalances[earmark.id] ?? zero,
        spent: sources.earmark.convertedSpentAmounts[earmark.id],
        budget: nil,
        savingsGoal: earmark.savingsGoal,
        saved: sources.earmark.convertedSavedAmounts[earmark.id],
        savingsStartDate: earmark.savingsStartDate,
        savingsEndDate: earmark.savingsEndDate,
        isHidden: earmark.isHidden)
    }
  }
}
