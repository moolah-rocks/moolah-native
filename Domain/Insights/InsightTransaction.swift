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

extension InsightTransaction {
  /// Flatten transactions into per-leg income/expense records, converting
  /// each leg's amount to the reporting currency via `convert`.
  ///
  /// Only `.income` and `.expense` legs are emitted — transfers, opening
  /// balances, and trades are excluded because they don't represent
  /// discretionary spend or earned income. A leg whose conversion returns
  /// `nil` (rate unavailable) is dropped rather than guessed, per
  /// `guides/INSTRUMENT_CONVERSION_GUIDE.md` Rule 11; callers that need a
  /// "data incomplete" signal should compare counts.
  ///
  /// `convert` receives the leg amount and the transaction date and returns
  /// the equivalent quantity in the reporting currency, or `nil` on failure.
  static func records(
    from transactions: [Transaction],
    categories: Categories,
    convert: (InstrumentAmount, Date) -> Decimal?
  ) -> [InsightTransaction] {
    var records: [InsightTransaction] = []
    for transaction in transactions {
      let normalized = PayeeNormalizer.normalize(transaction.payee)
      for leg in transaction.legs where leg.type == .income || leg.type == .expense {
        guard let quantity = convert(leg.amount, transaction.date) else { continue }
        let path = leg.categoryId
          .flatMap { categories.by(id: $0) }
          .map { categories.path(for: $0) }
        records.append(
          InsightTransaction(
            id: transaction.id,
            date: transaction.date,
            rawPayee: transaction.payee,
            normalizedPayee: normalized,
            amount: quantity,
            categoryId: leg.categoryId,
            categoryPath: path,
            type: leg.type,
            accountId: leg.accountId))
      }
    }
    return records
  }

  /// Convenience builder for single-currency profiles (or any caller that
  /// has already pre-converted): keeps only legs already denominated in
  /// `reportingCurrency` and uses their quantity directly. Mixed-currency
  /// profiles must use `records(from:categories:convert:)` with a real
  /// converter.
  static func sameCurrencyRecords(
    from transactions: [Transaction],
    categories: Categories,
    reportingCurrency: Instrument
  ) -> [InsightTransaction] {
    records(from: transactions, categories: categories) { amount, _ in
      amount.instrument == reportingCurrency ? amount.quantity : nil
    }
  }
}
