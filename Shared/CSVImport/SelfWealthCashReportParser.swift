import Foundation

/// Parser for SelfWealth's "Cash Report" — pure cash-flow ledger.
///
/// Trade-related rows (`Order N: …`) are deliberately skipped because they're
/// already represented in the Movements report. The two parsers split scope
/// by design: Movements owns positions + trades, Cash Report owns deposits,
/// withdrawals, and cash dividends. Importing both reports for the same
/// account therefore double-counts nothing.
///
/// Cash dividends follow the pattern `<TICKER> PAYMENT <MMMYY>/<digits>`. The
/// raw comment is stored verbatim as the `bankReference` because SelfWealth's
/// formatting may shift over time and we want re-imports of the same row to
/// dedupe against the original value, not a normalised one.
///
/// Anything else with a Credit or Debit amount is treated as an opaque cash
/// transfer. SelfWealth passes the user's bank's narration through verbatim
/// (`PAYMENT FROM <name>`, `Funds transfer`, plain `SelfWealth`, etc.), so no
/// keyword match is safe — the raw `Comment` becomes `rawDescription` and
/// the user's import rules can categorise it.
struct SelfWealthCashReportParser: CSVParser, Sendable {

  let identifier = "selfwealth-cash-report"

  func recognizes(headers: [String]) -> Bool {
    let normalised = headers.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    let needsTransactionDate = normalised.contains("transactiondate")
    let needsComment = normalised.contains("comment")
    let needsCredit = normalised.contains("credit")
    let needsDebit = normalised.contains("debit")
    // The Balance header has a trailing comment glued onto it
    // (`Balance * Please note, this is not a bank statement.`). Match the
    // prefix so SelfWealth tweaking the wording later doesn't break us.
    let needsBalance = normalised.contains(where: { $0.hasPrefix("balance") })
    return needsTransactionDate && needsComment && needsCredit && needsDebit && needsBalance
  }

  func parse(rows: [[String]]) throws -> [ParsedRecord] {
    guard let headers = rows.first else { throw CSVParserError.emptyFile }
    guard recognizes(headers: headers) else { throw CSVParserError.headerMismatch }
    let columns = try columnIndex(headers)

    var results: [ParsedRecord] = []
    for (offset, row) in rows.dropFirst().enumerated() {
      let rowIndex = offset + 1
      if row.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
        results.append(.skip(reason: "blank row"))
        continue
      }
      results.append(try parseDataRow(row, columns: columns, rowIndex: rowIndex))
    }
    return results
  }

  // MARK: - Private

  private struct Columns {
    let transactionDate: Int
    let comment: Int
    let credit: Int
    let debit: Int
    let balance: Int
  }

  private func columnIndex(_ headers: [String]) throws -> Columns {
    let normalised = headers.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    guard let date = normalised.firstIndex(of: "transactiondate"),
      let comment = normalised.firstIndex(of: "comment"),
      let credit = normalised.firstIndex(of: "credit"),
      let debit = normalised.firstIndex(of: "debit"),
      let balance = normalised.firstIndex(where: { $0.hasPrefix("balance") })
    else {
      throw CSVParserError.headerMismatch
    }
    return Columns(
      transactionDate: date, comment: comment, credit: credit, debit: debit, balance: balance)
  }

  private func parseDataRow(
    _ row: [String], columns: Columns, rowIndex: Int
  ) throws -> ParsedRecord {
    let dateField = SelfWealthCSVParsing.safe(row, columns.transactionDate)
      .trimmingCharacters(in: .whitespaces)
    let comment = SelfWealthCSVParsing.safe(row, columns.comment)
      .trimmingCharacters(in: .whitespaces)
    let credit =
      SelfWealthCSVParsing.parseDecimal(
        SelfWealthCSVParsing.safe(row, columns.credit)) ?? 0
    let debit =
      SelfWealthCSVParsing.parseDecimal(
        SelfWealthCSVParsing.safe(row, columns.debit)) ?? 0
    let balance = SelfWealthCSVParsing.parseDecimal(
      SelfWealthCSVParsing.safe(row, columns.balance))

    // Opening / Closing Balance rows have no date and no amount — they're
    // sentinels, not transactions.
    if dateField.isEmpty {
      return .skip(reason: "balance sentinel")
    }
    // Trade rows belong to the Movements report.
    if comment.lowercased().hasPrefix("order ") {
      return .skip(reason: "trade row — represented in Movements report")
    }
    guard let date = SelfWealthCSVParsing.parseDate(dateField) else {
      throw CSVParserError.malformedRow(
        index: rowIndex, reason: "invalid date: \(dateField)", row: row)
    }
    if credit == 0 && debit == 0 {
      return .skip(reason: "row has no credit or debit value")
    }

    let isDividend =
      Self.dividendRegex.regex.firstMatch(
        in: comment,
        options: [],
        range: NSRange(comment.startIndex..., in: comment)) != nil
    let bankReference: String? = isDividend ? comment : nil

    // SelfWealth's Debit column is always a positive magnitude; negate to
    // produce a signed expense. Preserves the project's sign convention
    // (a hypothetical negative Debit would flip to income, which is the
    // correct semantics for a refund-shaped row).
    let amount: Decimal = credit != 0 ? credit : -debit
    let leg = ParsedLeg(
      accountId: nil,
      instrument: .AUD,
      quantity: amount,
      type: amount >= 0 ? .income : .expense,
      isInstrumentPlaceholder: true)

    return .transaction(
      ParsedTransaction(
        date: date,
        legs: [leg],
        rawRow: row,
        rawDescription: comment,
        rawAmount: amount,
        rawBalance: balance,
        bankReference: bankReference))
  }

  /// `<TICKER> PAYMENT <MMMYY>/<digits>` — e.g. `WXYZ PAYMENT JAN24/0000001`.
  /// We don't try to extract the ticker; the comment is stored verbatim as
  /// the bank reference so re-imports dedupe against the original string.
  private static let dividendRegex: SendableRegex = {
    // Regex is a compile-time constant; force-try here cannot fail at runtime.
    // swiftlint:disable:next force_try
    let compiled = try! NSRegularExpression(
      pattern: #"^[A-Z]+\s+PAYMENT\s+\w+/\d+$"#,
      options: [])
    return SendableRegex(regex: compiled)
  }()

  /// NSRegularExpression is documented thread-safe for matching operations
  /// but isn't `Sendable` in Swift's type system. Wrap it in an
  /// `@unchecked Sendable` box so a strict-concurrency build doesn't flag
  /// the static shared instance.
  private struct SendableRegex: @unchecked Sendable {
    let regex: NSRegularExpression
  }
}
