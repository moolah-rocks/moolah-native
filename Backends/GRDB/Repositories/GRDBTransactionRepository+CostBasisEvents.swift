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
  /// **Membership excludes fiat, not "includes registered non-fiat".** The
  /// plan's original design inner-joined a per-profile `instrument` table to
  /// filter on `kind != 'fiatCurrency'`, but that table was dropped by
  /// `v10_drop_shared_instrument_legacy` — instrument identity now lives
  /// solely in the shared profile-index registry. Filtering by the
  /// *registered non-fiat* ids would be both huge (every crypto + spam
  /// token) and **wrong**: a non-fiat instrument deregistered from the
  /// registry (e.g. via Manage Crypto Tokens) drops out of `instrumentMap()`,
  /// so its historical legs — and their realised CGT — would vanish. Fiat is
  /// instead the small, stable, registry-independent set (ISO 4217 codes
  /// unioned with any stored `.fiatCurrency` ids), and the membership
  /// subquery keeps any transaction touching a leg whose `instrument_id` is
  /// **NOT** a fiat code. Crypto/stock ids contain `:` so never collide with
  /// three-letter ISO codes; a deregistered crypto id is therefore still a
  /// non-fiat leg and its transaction is still returned. The fiat id list is
  /// bound into the subquery via GRDB's sequence-interpolation escape hatch
  /// (`DATABASE_CODE_GUIDE.md` §4; the ids are ISO/registry data, never
  /// end-user free text). The pure-fiat bulk of the table still never leaves
  /// SQLite — only the legs of non-fiat-touching transactions materialise.
  func fetchCostBasisEventLegs() async throws -> [CostBasisEventLegRow] {
    // Resolve the instrument lookup table before opening the per-profile
    // snapshot: the canonical registry is a separate database, so the
    // map cannot be joined into this transaction. See
    // `GRDBTransactionRepository.instrumentResolver`.
    let instruments = try await instrumentResolver.instrumentMap()
    // The fiat id set: every ISO 4217 currency code (a fixed, host-stable
    // table) unioned with any stored `.fiatCurrency` instrument in the map,
    // sorted for a deterministic bound-argument order. Registry-independent,
    // so deregistering a crypto token never enlarges or shrinks it.
    let fiatInstrumentIds =
      Set(Locale.Currency.isoCurrencies.map(\.identifier))
      .union(instruments.filter { $0.value.kind == .fiatCurrency }.keys)
      .sorted()
    // ISO 4217 guarantees a non-empty set in practice; guard anyway so a
    // theoretical empty set never emits invalid `NOT IN ()` SQL — with no
    // fiat codes to exclude, every non-recurring leg qualifies.
    guard !fiatInstrumentIds.isEmpty else {
      return try await database.read { database -> [CostBasisEventLegRow] in
        let rows = try SQLRequest<Row>(literal: Self.costBasisEventLegsAllLegsSQL).fetchAll(
          database)
        return rows.compactMap { row in Self.mapCostBasisEventLegRow(row, instruments: instruments)
        }
      }
    }

    return try await database.read { database -> [CostBasisEventLegRow] in
      let rows = try SQLRequest<Row>(
        literal: Self.costBasisEventLegsSQL(fiatInstrumentIds: fiatInstrumentIds)
      ).fetchAll(database)
      return rows.compactMap { row in Self.mapCostBasisEventLegRow(row, instruments: instruments) }
    }
  }

  /// The cost-basis key-event legs query. A transaction qualifies when it
  /// touches at least one leg whose `instrument_id` is **not** in the bound
  /// fiat id list (interpolated as bound placeholders). Exposed (not
  /// file-private) so `CostBasisEventLegsPlanPinningTests` pins the exact
  /// literal the production read runs. `t.recur_period IS NULL` excludes
  /// scheduled templates, matching every other analysis query.
  static func costBasisEventLegsSQL(fiatInstrumentIds: [String]) -> SQL {
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
          WHERE nf.instrument_id NOT IN \(fiatInstrumentIds)
      )
    ORDER BY t.date ASC, leg.transaction_id ASC, leg.sort_order ASC
    """
  }

  /// Fallback query for the (theoretical) empty-fiat-set case: every leg of
  /// every non-recurring transaction, same projection and ordering. The
  /// builder ignores pure-fiat legs, so the result is correct — only less
  /// reduced.
  private static let costBasisEventLegsAllLegsSQL: SQL = """
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
    ORDER BY t.date ASC, leg.transaction_id ASC, leg.sort_order ASC
    """

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
