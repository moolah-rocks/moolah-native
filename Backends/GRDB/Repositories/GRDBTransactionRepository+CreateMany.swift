// Backends/GRDB/Repositories/GRDBTransactionRepository+CreateMany.swift

import Foundation
import GRDB

extension GRDBTransactionRepository {
  // MARK: - Non-fiat instrument registration

  /// Awaits `registerResolvable` once per distinct non-fiat instrument
  /// referenced by `legs`, in first-seen order. Shared by `create`,
  /// `createMany`, and `update` so the registration contract is
  /// identical regardless of write shape, and called *before* the
  /// per-profile write so a reader immediately after resolves it. Fiat
  /// is skipped by the registrar itself; the de-dup keeps a transaction
  /// whose N legs share one new instrument to a single registration
  /// call.
  static func registerNonFiatLegInstruments(
    _ legs: [TransactionLeg],
    using registrar: any InstrumentRegistering
  ) async throws {
    var seenInstrumentIds: Set<String> = []
    for leg in legs where leg.instrument.kind != .fiatCurrency {
      guard seenInstrumentIds.insert(leg.instrument.id).inserted else { continue }
      try await registrar.registerResolvable(leg.instrument)
    }
  }

  // MARK: - Bulk create pipeline

  /// Inserts every transaction header and its legs inside one
  /// `database.write { … }` transaction and returns every inserted leg
  /// id (flat, input order) for the post-commit per-leg sync hook. On
  /// any throw the whole batch rolls back; the caller in the main file
  /// fires `onRecordChanged` only after the write commits. Non-fiat
  /// instrument registration happens *before* this write via
  /// `registerNonFiatLegInstruments` — see
  /// `GRDBTransactionRepository.createMany(_:)`.
  static func performCreateMany(
    database: Database,
    transactions: [Transaction]
  ) throws -> [UUID] {
    var legIds: [UUID] = []
    legIds.reserveCapacity(transactions.reduce(0) { $0 + $1.legs.count })

    for transaction in transactions {
      let txnRow = TransactionRow(domain: transaction)
      try txnRow.insert(database)
      try markTransactionNeedsPush(id: transaction.id, in: database)

      for (index, leg) in transaction.legs.enumerated() {
        let legRow = TransactionLegRow(
          id: leg.id,
          domain: leg,
          transactionId: transaction.id,
          sortOrder: index)
        try legRow.insert(database)
        try markLegNeedsPush(id: leg.id, in: database)
        legIds.append(leg.id)
      }
    }
    return legIds
  }
}
