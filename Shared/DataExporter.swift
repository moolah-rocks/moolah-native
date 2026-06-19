import Foundation
import os

/// Exports all data from repository protocols (works with any BackendProvider).
actor DataExporter {
  private let backend: any BackendProvider

  enum ExportProgress: Sendable {
    case downloading(step: String)
    case downloadComplete(ExportedData)
    case failed(Error)
  }

  init(backend: any BackendProvider) {
    self.backend = backend
  }

  func export(
    profileLabel: String,
    currencyCode: String,
    financialYearStartMonth: Int,
    progress: @escaping @Sendable (ExportProgress) -> Void
  ) async throws -> ExportedData {
    let signpostID = OSSignpostID(log: Signposts.export)
    os_signpost(.begin, log: Signposts.export, name: "DataExporter.export", signpostID: signpostID)
    defer {
      os_signpost(.end, log: Signposts.export, name: "DataExporter.export", signpostID: signpostID)
    }

    let stages = try await downloadAllStages(progress: progress, signpostID: signpostID)
    let data = buildExportedData(
      stages: stages,
      profileLabel: profileLabel,
      currencyCode: currencyCode,
      financialYearStartMonth: financialYearStartMonth)
    progress(.downloadComplete(data))
    return data
  }

  /// Holds the raw per-stage download output before it's assembled into an
  /// `ExportedData`, letting `export()` delegate the download fan-out and
  /// the assembly to separate helpers.
  private struct StagedDownloads {
    let accounts: [Account]
    let accountGroups: [AccountGroup]
    let categories: [Category]
    let earmarks: [Earmark]
    let earmarkBudgets: [UUID: [EarmarkBudgetItem]]
    let transactions: [Transaction]
    let investmentValues: [UUID: [InvestmentValue]]
  }

  private func downloadAllStages(
    progress: @escaping @Sendable (ExportProgress) -> Void,
    signpostID: OSSignpostID
  ) async throws -> StagedDownloads {
    progress(.downloading(step: "accounts"))
    let accounts = try await runStage(
      "accounts", signpost: "export.accounts", signpostID: signpostID
    ) {
      try await backend.accounts.fetchAll()
    }

    progress(.downloading(step: "account groups"))
    let accountGroups = try await runStage(
      "account groups", signpost: "export.accountGroups", signpostID: signpostID
    ) {
      try await backend.accountGroups.fetchAll()
    }

    progress(.downloading(step: "categories"))
    let categories = try await runStage(
      "categories", signpost: "export.categories", signpostID: signpostID
    ) {
      try await backend.categories.fetchAll()
    }

    progress(.downloading(step: "earmarks"))
    let (earmarks, budgets) = try await runStage(
      "earmarks", signpost: "export.earmarks", signpostID: signpostID
    ) {
      try await downloadEarmarksWithBudgets()
    }

    progress(.downloading(step: "transactions"))
    let transactions = try await runStage(
      "transactions", signpost: "export.transactions", signpostID: signpostID
    ) {
      try await fetchAllTransactions()
    }

    progress(.downloading(step: "investment values"))
    let investmentValues = try await runStage(
      "investment values", signpost: "export.investmentValues", signpostID: signpostID
    ) {
      var values: [UUID: [InvestmentValue]] = [:]
      for account in accounts where account.type == .investment {
        values[account.id] = try await fetchAllInvestmentValues(accountId: account.id)
      }
      return values
    }

    return StagedDownloads(
      accounts: accounts,
      accountGroups: accountGroups,
      categories: categories,
      earmarks: earmarks,
      earmarkBudgets: budgets,
      transactions: transactions,
      investmentValues: investmentValues)
  }

  /// Fetch every earmark plus its budget items, keyed by earmark id. Pulled
  /// out of `downloadAllStages` so the earmarks stage closure stays a single
  /// call, keeping that orchestration method focused on the per-stage fan-out.
  private func downloadEarmarksWithBudgets() async throws -> (
    [Earmark], [UUID: [EarmarkBudgetItem]]
  ) {
    let earmarks = try await backend.earmarks.fetchAll()
    var budgets: [UUID: [EarmarkBudgetItem]] = [:]
    for earmark in earmarks {
      budgets[earmark.id] = try await backend.earmarks.fetchBudget(earmarkId: earmark.id)
    }
    return (earmarks, budgets)
  }

  private func buildExportedData(
    stages: StagedDownloads,
    profileLabel: String,
    currencyCode: String,
    financialYearStartMonth: Int
  ) -> ExportedData {
    let instruments = collectInstruments(
      currencyCode: currencyCode,
      accounts: stages.accounts,
      accountGroups: stages.accountGroups,
      transactions: stages.transactions)
    return ExportedData(
      version: 1,
      exportedAt: Date(),
      profileLabel: profileLabel,
      currencyCode: currencyCode,
      financialYearStartMonth: financialYearStartMonth,
      instruments: instruments,
      accounts: stages.accounts,
      accountGroups: stages.accountGroups,
      categories: stages.categories,
      earmarks: stages.earmarks,
      earmarkBudgets: stages.earmarkBudgets,
      transactions: stages.transactions,
      investmentValues: stages.investmentValues
    )
  }

  /// Wraps `body` in a signpost region and maps any thrown error to
  /// `ExportError.exportFailed(step:)`. Keeps per-stage instrumentation
  /// out of the main `export` function so it remains readable.
  private func runStage<Value: Sendable>(
    _ step: String,
    signpost: StaticString,
    signpostID: OSSignpostID,
    _ body: @Sendable () async throws -> Value
  ) async throws -> Value {
    os_signpost(.begin, log: Signposts.export, name: signpost, signpostID: signpostID)
    defer { os_signpost(.end, log: Signposts.export, name: signpost, signpostID: signpostID) }
    do {
      return try await body()
    } catch {
      throw ExportError.exportFailed(step: step, underlying: error)
    }
  }

  private func collectInstruments(
    currencyCode: String,
    accounts: [Account],
    accountGroups: [AccountGroup],
    transactions: [Transaction]
  ) -> [Instrument] {
    let profileInstrument = Instrument.fiat(code: currencyCode)
    var instrumentsById: [String: Instrument] = [profileInstrument.id: profileInstrument]
    for account in accounts {
      instrumentsById[account.instrument.id] = account.instrument
    }
    for group in accountGroups {
      instrumentsById[group.instrument.id] = group.instrument
    }
    for txn in transactions {
      for leg in txn.legs {
        instrumentsById[leg.instrument.id] = leg.instrument
      }
    }
    return Array(instrumentsById.values)
  }

  private func fetchAllTransactions() async throws -> [Transaction] {
    let nonScheduled = try await backend.transactions.fetchAll(
      filter: TransactionFilter())
    let scheduled = try await backend.transactions.fetchAll(
      filter: TransactionFilter(scheduled: .scheduledOnly))
    let existingIds = Set(nonScheduled.map(\.id))
    return nonScheduled + scheduled.filter { !existingIds.contains($0.id) }
  }

  private func fetchAllInvestmentValues(accountId: UUID) async throws -> [InvestmentValue] {
    var allValues: [InvestmentValue] = []
    var page = 0
    let pageSize = 200

    while true {
      let result = try await backend.investments.fetchValues(
        accountId: accountId,
        page: page,
        pageSize: pageSize
      )
      allValues.append(contentsOf: result.values)

      if result.values.count < pageSize {
        break
      }
      page += 1
    }

    return allValues
  }
}
