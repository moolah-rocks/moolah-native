import Foundation

/// A flattened, currency-normalised view of one income or expense leg,
/// shaped for the statistical detectors.
///
/// Detectors must stay pure and synchronous, but currency conversion is
/// async (`InstrumentConversionService`). The boundary is drawn here: the
/// wiring layer converts each leg's amount to the reporting currency once,
/// up front, and feeds detectors a flat array of `InsightTransaction`
/// already denominated in a single instrument. Detectors then do
/// instrument-safe arithmetic without ever touching the conversion service.
///
/// **Sign convention** (`guides/CODE_GUIDE.md` §16): `amount` is signed in
/// the reporting currency — income positive, expense negative, refunds
/// (positive-valued expense legs) preserved with their real sign. Detectors
/// must never `abs()` it; they derive spend magnitude explicitly via
/// `spendMagnitude`.
struct InsightTransaction: Sendable, Identifiable, Hashable {
  /// The owning transaction's id (not the leg's) — multiple records can
  /// share it when a transaction splits across categories.
  let id: UUID
  let date: Date
  let rawPayee: String?
  /// `rawPayee` run through `PayeeNormalizer` — the clustering key for
  /// subscription and new-merchant detection. Empty when no payee.
  let normalizedPayee: String
  let amount: Decimal
  let categoryId: UUID?
  let categoryPath: String?
  let type: TransactionType
  let accountId: UUID?

  init(
    id: UUID,
    date: Date,
    rawPayee: String?,
    normalizedPayee: String,
    amount: Decimal,
    categoryId: UUID?,
    categoryPath: String?,
    type: TransactionType,
    accountId: UUID?
  ) {
    self.id = id
    self.date = date
    self.rawPayee = rawPayee
    self.normalizedPayee = normalizedPayee
    self.amount = amount
    self.categoryId = categoryId
    self.categoryPath = categoryPath
    self.type = type
    self.accountId = accountId
  }

  /// Positive magnitude of money that left the account for an expense, or
  /// `0` for a refund / inflow. Spend-oriented detectors aggregate this;
  /// it deliberately collapses refunds to `0` rather than `abs()`-ing the
  /// inflow into a spurious outflow.
  var spendMagnitude: Decimal {
    amount < 0 ? -amount : 0
  }

  /// Positive magnitude of money received as income, or `0` for an outflow.
  var incomeMagnitude: Decimal {
    amount > 0 ? amount : 0
  }

  var isExpense: Bool { type == .expense }
  var isIncome: Bool { type == .income }
}
