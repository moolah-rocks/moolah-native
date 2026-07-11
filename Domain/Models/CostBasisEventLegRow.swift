import Foundation

/// One reduced `transaction_leg` row returned by the cost-basis key-event
/// query, carrying its parent transaction's date and a resolved
/// `Instrument` (via the injected instrument map). `HoldingsCostLedger`
/// groups these back into per-transaction event inputs. Only legs of
/// transactions touching at least one non-fiat instrument are produced —
/// the pure-fiat bulk of the table never leaves SQLite.
struct CostBasisEventLegRow: Sendable, Equatable {
  let id: UUID
  let transactionId: UUID
  let date: Date
  let accountId: UUID?
  let instrument: Instrument
  /// Signed leg quantity in `instrument` units (already de-scaled from the
  /// `INTEGER` Decimal×10^8 storage form via `InstrumentAmount`).
  let quantity: Decimal
  let type: TransactionType
  let sortOrder: Int
  /// Current tax-owner assignment for the holding account. Empty preserves
  /// legacy unowned cost-basis callers.
  let taxOwnerIds: [UUID]

  init(
    id: UUID = UUID(),
    transactionId: UUID,
    date: Date,
    accountId: UUID?,
    instrument: Instrument,
    quantity: Decimal,
    type: TransactionType,
    sortOrder: Int,
    taxOwnerIds: [UUID] = []
  ) {
    self.id = id
    self.transactionId = transactionId
    self.date = date
    self.accountId = accountId
    self.instrument = instrument
    self.quantity = quantity
    self.type = type
    self.sortOrder = sortOrder
    self.taxOwnerIds = taxOwnerIds
  }
}
