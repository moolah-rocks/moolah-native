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
  ///
  /// `preservedTransactionFields` / `preservedLegFields` carry the cached
  /// `encoded_system_fields` blobs of rows being deleted in the same
  /// `replace` write, keyed by record id and STRICTLY per record type (a
  /// header map and a leg map — never one flat `[UUID: Data?]`, so a leg
  /// blob can never cross-attach to a header that happens to share a UUID).
  /// When a re-created row reuses a deleted row's id, its blob is re-attached
  /// here so the row keeps its CloudKit sync identity and the #1085 gate
  /// protects it; a row whose id is absent from the map lands with `nil`
  /// (a genuine new record). Both default to empty, so `createMany` inserts
  /// fresh rows with `nil` blobs exactly as before. See issue #1090 follow-up.
  static func performCreateMany(
    database: Database,
    transactions: [Transaction],
    preservedTransactionFields: [UUID: Data?] = [:],
    preservedLegFields: [UUID: Data?] = [:]
  ) throws -> [UUID] {
    var legIds: [UUID] = []
    legIds.reserveCapacity(transactions.reduce(0) { $0 + $1.legs.count })

    for transaction in transactions {
      var txnRow = TransactionRow(domain: transaction)
      // Re-attach a reused header's cached blob (outer `if let` unwraps the
      // map miss; an existing entry carrying `nil` still overwrites).
      if let preserved = preservedTransactionFields[transaction.id] {
        txnRow.encodedSystemFields = preserved
      }
      try txnRow.insert(database)
      try markTransactionNeedsPush(id: transaction.id, in: database)

      for (index, leg) in transaction.legs.enumerated() {
        var legRow = TransactionLegRow(
          id: leg.id,
          domain: leg,
          transactionId: transaction.id,
          sortOrder: index)
        if let preserved = preservedLegFields[leg.id] {
          legRow.encodedSystemFields = preserved
        }
        try legRow.insert(database)
        try markLegNeedsPush(id: leg.id, in: database)
        legIds.append(leg.id)
      }
    }
    return legIds
  }
}
