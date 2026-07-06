import Foundation

/// One reduced `transaction_leg` row returned by the cost-basis key-event
/// query, carrying its parent transaction's date and a resolved
/// `Instrument` (via the injected instrument map). `HoldingsCostLedger`
/// groups these back into per-transaction event inputs. Only legs of
/// transactions touching at least one non-fiat instrument are produced —
/// the pure-fiat bulk of the table never leaves SQLite.
struct CostBasisEventLegRow: Sendable, Equatable {
  let transactionId: UUID
  let date: Date
  let accountId: UUID?
  let instrument: Instrument
  /// Signed leg quantity in `instrument` units (already de-scaled from the
  /// `INTEGER` Decimal×10^8 storage form via `InstrumentAmount`).
  let quantity: Decimal
  let type: TransactionType
  let sortOrder: Int
}
