import Foundation
import GRDB
import OSLog

struct ImportResult: Sendable {
  let accountCount: Int
  let accountGroupCount: Int
  let categoryCount: Int
  let earmarkCount: Int
  let budgetItemCount: Int
  let transactionCount: Int
  let investmentValueCount: Int

  var totalCount: Int {
    accountCount + accountGroupCount + categoryCount + earmarkCount + budgetItemCount
      + transactionCount + investmentValueCount
  }
}

/// Imports exported data into a profile's GRDB-backed `data.sqlite`,
/// which is the canonical store the runtime reads from. The GRDB writes
/// are queue-serialised inside `database.write`, so the importer itself
/// does not need any actor isolation.
///
/// Instrument identity is **not** written to `data.sqlite`: there is no
/// per-profile `instrument` table. Every non-fiat denomination the import
/// references is registered through the injected
/// `InstrumentRegistering` (production = the shared profile-index
/// registry) before the per-profile rows are written, so a read issued
/// after the import resolves each leg / account instrument. Fiat is
/// ambient (ISO fallback) and needs no registration. The registrar is
/// optional only so callers without a registry (a few tests) still
/// construct; production always injects one.
struct CloudKitDataImporter {
  private let database: any DatabaseWriter
  private let currencyCode: String
  private let instrumentRegistrar: (any InstrumentRegistering)?
  private let logger = Logger(subsystem: "com.moolah.app", category: "Import")

  init(
    database: any DatabaseWriter,
    currencyCode: String,
    instrumentRegistrar: (any InstrumentRegistering)? = nil
  ) {
    self.database = database
    self.currencyCode = currencyCode
    self.instrumentRegistrar = instrumentRegistrar
  }

  @discardableResult
  func importData(
    _ data: ExportedData,
    progress: ((String, Double) -> Void)? = nil
  ) async throws -> ImportResult {
    // The GRDB write is a single transaction, so per-stage progress is
    // approximate: fire "saving" before the transaction so the call site
    // can render a spinner, yield once so the progress callback can be
    // observed, then write everything, then fire "done".
    progress?("saving", 0.0)
    await Task.yield()

    try await writeGRDB(data: data)

    progress?("done", 1.0)

    let budgetItemCount = data.earmarkBudgets.values.reduce(0) { $0 + $1.count }
    let investmentValueCount = data.investmentValues.values.reduce(0) { $0 + $1.count }

    logger.info(
      "Import complete: \(data.accounts.count) accounts, \(data.accountGroups.count) groups, \(data.transactions.count) transactions, \(investmentValueCount) investment values"
    )

    return ImportResult(
      accountCount: data.accounts.count,
      accountGroupCount: data.accountGroups.count,
      categoryCount: data.categories.count,
      earmarkCount: data.earmarks.count,
      budgetItemCount: budgetItemCount,
      transactionCount: data.transactions.count,
      investmentValueCount: investmentValueCount
    )
  }

  // MARK: - GRDB writes

  /// Writes every record type from `data` into the per-profile GRDB
  /// database. Parents go first so FK references resolve as the single
  /// `database.write` transaction commits; non-fiat instruments are
  /// upserted up-front so accounts and legs that reference them by id
  /// can resolve their full domain `Instrument` on read.
  private func writeGRDB(data: ExportedData) async throws {
    // Register every non-fiat denomination on the shared registry
    // *before* the per-profile write so a read after import resolves
    // each leg / account instrument. There is no per-profile `instrument`
    // table; fiat is ambient and a no-op in `registerResolvable`.
    try await registerInstruments(data: data)
    try await database.write { database in
      try Self.writeCategories(data: data, database: database)
      // Groups before accounts so a member's `groupId` resolves to a
      // present group row (the schema omits the FK constraint to allow
      // out-of-order sync delivery, but a clean import writes parents first).
      try Self.writeAccountGroups(data: data, database: database)
      try Self.writeAccountsAndEarmarks(data: data, database: database)
      try Self.writeTransactions(data: data, database: database)
      try Self.writeInvestmentValues(data: data, database: database)
    }
  }

  /// Registers every distinct non-fiat instrument the import references
  /// (the explicit `data.instruments` list plus account / leg
  /// denominations) through the shared registry. Idempotent; fiat is
  /// skipped by `registerResolvable`.
  private func registerInstruments(data: ExportedData) async throws {
    guard let instrumentRegistrar else {
      // Production always supplies a registrar (see the call site in
      // ProfileSession's backend build). A nil registrar is a
      // test-only wiring; if the import nonetheless carries any
      // non-fiat instrument (stock / crypto), those denominations will
      // be unresolvable on read-back because there is nowhere to
      // register them. Make that loud rather than silently importing
      // rows that later fail to resolve.
      let hasNonFiat =
        data.instruments.contains { $0.kind != .fiatCurrency }
        || data.accounts.contains { $0.instrument.kind != .fiatCurrency }
        || data.accountGroups.contains { $0.instrument.kind != .fiatCurrency }
        || data.transactions.contains { txn in
          txn.legs.contains { $0.instrument.kind != .fiatCurrency }
        }
      if hasNonFiat {
        logger.fault(
          "Import carries non-fiat instruments but no instrumentRegistrar was supplied; those denominations will be unresolvable on read-back"
        )
      }
      return
    }
    var seen: Set<String> = []
    func register(_ instrument: Instrument) async throws {
      guard instrument.kind != .fiatCurrency, seen.insert(instrument.id).inserted
      else { return }
      try await instrumentRegistrar.registerResolvable(instrument)
    }
    for instrument in data.instruments {
      try await register(instrument)
    }
    for account in data.accounts {
      try await register(account.instrument)
    }
    for group in data.accountGroups {
      try await register(group.instrument)
    }
    for txn in data.transactions {
      for leg in txn.legs {
        try await register(leg.instrument)
      }
    }
  }

  nonisolated private static func writeCategories(
    data: ExportedData, database: Database
  ) throws {
    for category in data.categories {
      try CategoryRow(domain: category).upsert(database)
    }
  }

  nonisolated private static func writeAccountGroups(
    data: ExportedData, database: Database
  ) throws {
    for group in data.accountGroups {
      try AccountGroupRow(domain: group).upsert(database)
    }
  }

  nonisolated private static func writeAccountsAndEarmarks(
    data: ExportedData, database: Database
  ) throws {
    for account in data.accounts {
      try AccountRow(domain: account).upsert(database)
    }
    for earmark in data.earmarks {
      try EarmarkRow(domain: earmark).upsert(database)
    }
    for (earmarkId, items) in data.earmarkBudgets {
      for item in items {
        try EarmarkBudgetItemRow(domain: item, earmarkId: earmarkId).upsert(database)
      }
    }
  }

  nonisolated private static func writeTransactions(
    data: ExportedData, database: Database
  ) throws {
    for txn in data.transactions {
      try TransactionRow(domain: txn).upsert(database)
      for (index, leg) in txn.legs.enumerated() {
        // Non-fiat denominations were registered on the shared registry
        // by `registerInstruments` before this transaction; there is no
        // per-profile `instrument` table.
        try TransactionLegRow(domain: leg, transactionId: txn.id, sortOrder: index)
          .upsert(database)
      }
    }
  }

  nonisolated private static func writeInvestmentValues(
    data: ExportedData, database: Database
  ) throws {
    for (accountId, values) in data.investmentValues {
      for value in values {
        try InvestmentValueRow(domain: value, accountId: accountId).upsert(database)
      }
    }
  }
}
