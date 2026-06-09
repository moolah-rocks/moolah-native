import Foundation

/// Aggregated expenses for one category in one financial month.
struct ExpenseBreakdown: Sendable, Identifiable, Hashable {
  var id: String { "\(categoryId?.uuidString ?? "uncategorized")-\(month)" }

  /// The category (nil means uncategorized expenses)
  let categoryId: UUID?

  /// Financial month in YYYYMM format (e.g., "202604" for April 2026 financial month)
  /// Grouped by user's monthEnd preference (e.g., Jan 26 – Feb 25 = "202602")
  let month: String

  /// Signed sum of the month's expense legs — negative for net spend (a
  /// net-refund month can be positive), matching the project's sign
  /// convention. Use `CategorySpendSeries` to derive positive spend magnitudes.
  let totalExpenses: InstrumentAmount

  /// True when one or more rows in this month could not be priced due to a
  /// transient conversion error (e.g. crypto prices not yet warmed). The
  /// displayed totals may be understated; callers should surface this state.
  let hasUnavailableData: Bool

  // A memberwise init is retained (not redundant): `hasUnavailableData` has no
  // inline default — the default lives here — so the property stays a `let`
  // that `init(from:)` can still decode (an inline default would suppress
  // decoding). The default keeps every existing call site compiling.
  init(
    categoryId: UUID?,
    month: String,
    totalExpenses: InstrumentAmount,
    hasUnavailableData: Bool = false
  ) {
    self.categoryId = categoryId
    self.month = month
    self.totalExpenses = totalExpenses
    self.hasUnavailableData = hasUnavailableData
  }
}

extension ExpenseBreakdown: Codable {
  private enum CodingKeys: String, CodingKey {
    case categoryId
    case month
    case totalExpenses
    case hasUnavailableData
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    categoryId = try container.decodeIfPresent(UUID.self, forKey: .categoryId)
    month = try container.decode(String.self, forKey: .month)
    totalExpenses = try container.decode(InstrumentAmount.self, forKey: .totalExpenses)
    hasUnavailableData =
      (try container.decodeIfPresent(Bool.self, forKey: .hasUnavailableData)) ?? false
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(categoryId, forKey: .categoryId)
    try container.encode(month, forKey: .month)
    try container.encode(totalExpenses, forKey: .totalExpenses)
    try container.encode(hasUnavailableData, forKey: .hasUnavailableData)
  }
}

extension ExpenseBreakdown {
  /// The first day of this financial month as a chart-positioning token
  /// (first day at noon UTC, zone-invariant). See `FinancialMonth.date(forKey:)`.
  var monthDate: Date? {
    FinancialMonth.date(forKey: month)
  }
}
