// Backends/GRDB/Repositories/GRDBTransactionRepository+CostBasisEvents.swift

import Foundation
import GRDB

extension GRDBTransactionRepository {
  /// See `TransactionRepository.fetchCostBasisEventLegs()`. Returns the
  /// legs of only transactions that touch at least one non-fiat
  /// instrument, ordered `(date, transaction_id, sort_order)` so each
  /// transaction's legs stay contiguous and transactions stay in date
  /// order. Plan-pinned by `CostBasisEventLegsPlanPinningTests`.
  ///
  /// **Membership is a bound `IN` list, not a JOIN.** The plan's original
  /// design inner-joined a per-profile `instrument` table to filter on
  /// `kind != 'fiatCurrency'`, but that table was dropped by
  /// `v10_drop_shared_instrument_legacy` — instrument identity now lives
  /// solely in the shared profile-index registry, resolved here via
  /// `instrumentResolver` (the same map `fetch`/`fetchAll` use). The
  /// non-fiat instrument ids are therefore computed in Swift from that
  /// map and bound into the membership subquery's `IN (…)` via GRDB's
  /// sequence-interpolation escape hatch (`DATABASE_CODE_GUIDE.md` §4;
  /// instrument ids are registry data, never end-user free text). The
  /// pure-fiat bulk of the table still never leaves SQLite — only the
  /// legs of non-fiat-touching transactions are materialised to Swift.
  func fetchCostBasisEventLegs() async throws -> [CostBasisEventLegRow] {
    // Resolve the instrument lookup table before opening the per-profile
    // snapshot: the canonical registry is a separate database, so the
    // map cannot be joined into this transaction. See
    // `GRDBTransactionRepository.instrumentResolver`.
    let instruments = try await instrumentResolver.instrumentMap()
    // Sorted for a deterministic bound-argument order; the set is the
    // registered non-fiat (crypto / stock) instruments. Anything absent
    // from the map is ambient fiat (resolution falls back to
    // `Instrument.fiat(code:)`), so it is correctly excluded.
    let nonFiatInstrumentIds =
      instruments
      .filter { $0.value.kind != .fiatCurrency }
      .keys
      .sorted()
    // A fiat-only profile touches no non-fiat instrument — `IN ()` is a
    // syntax error and the result is empty by definition.
    guard !nonFiatInstrumentIds.isEmpty else { return [] }

    return try await database.read { database -> [CostBasisEventLegRow] in
      let rows = try SQLRequest<Row>(
        literal: Self.costBasisEventLegsSQL(nonFiatInstrumentIds: nonFiatInstrumentIds)
      ).fetchAll(database)
      return rows.compactMap { row in Self.mapCostBasisEventLegRow(row, instruments: instruments) }
    }
  }

  /// The cost-basis key-event legs query, with the non-fiat instrument-id
  /// membership list interpolated as bound placeholders. Exposed
  /// (not file-private) so `CostBasisEventLegsPlanPinningTests` pins the
  /// exact literal the production read runs. `t.recur_period IS NULL`
  /// excludes scheduled templates, matching every other analysis query.
  static func costBasisEventLegsSQL(nonFiatInstrumentIds: [String]) -> SQL {
    """
    SELECT
        leg.transaction_id  AS transaction_id,
        t.date              AS date,
        leg.account_id      AS account_id,
        leg.instrument_id   AS instrument_id,
        leg.quantity        AS quantity,
        leg.type            AS type,
        leg.sort_order      AS sort_order
    FROM transaction_leg leg
    JOIN "transaction" t ON leg.transaction_id = t.id
    WHERE t.recur_period IS NULL
      AND leg.transaction_id IN (
          SELECT nf.transaction_id
          FROM transaction_leg nf
          WHERE nf.instrument_id IN \(nonFiatInstrumentIds)
      )
    ORDER BY t.date ASC, leg.transaction_id ASC, leg.sort_order ASC
    """
  }

  /// Decode one key-event leg row, returning `nil` for malformed rows so
  /// the loop skips them without breaking the rest of the snapshot.
  static func mapCostBasisEventLegRow(
    _ row: Row, instruments: [String: Instrument]
  ) -> CostBasisEventLegRow? {
    guard
      let transactionId: UUID = row["transaction_id"],
      // GRDB decodes the `"transaction".date` TEXT column straight to
      // `Date` via the same DatabaseValueConvertible path `TransactionRow`
      // (`var date: Date`) uses on `fetch`/`fetchAll` — no hand-rolled
      // formatter.
      let date: Date = row["date"],
      let instrumentId: String = row["instrument_id"],
      let storage: Int64 = row["quantity"],
      let typeRaw: String = row["type"],
      let type = TransactionType(rawValue: typeRaw),
      let sortOrder: Int = row["sort_order"]
    else { return nil }
    let instrument = instruments[instrumentId] ?? Instrument.fiat(code: instrumentId)
    return CostBasisEventLegRow(
      transactionId: transactionId,
      date: date,
      accountId: row["account_id"],
      instrument: instrument,
      // Reuse the sanctioned Decimal×10^8 de-scaling — never hand-roll it.
      quantity: InstrumentAmount(storageValue: storage, instrument: instrument).quantity,
      type: type,
      sortOrder: sortOrder)
  }
}
