import Foundation

/// Parser for SelfWealth's "Movements" report — positions and trades only.
///
/// Each row has a single `Action` value (`Buy`, `Sell`, `In`, `Out`) that
/// determines the leg layout:
/// - `Buy` / `Sell` → three legs: cash AUD + position on `ASX:<Code>` + AUD
///   brokerage. Brokerage is broken out as its own fee leg on the same
///   transaction so #558 can later fold it into cost basis without re-parsing.
/// - `In` / `Out` → single position-only leg. SelfWealth uses `In` for both
///   DRP allocations and off-market transfers; the CSV doesn't distinguish
///   them, so we import both as position income (assume DRP) and let the user
///   reclassify in-app.
/// - Anything else → `.skip(reason:)` so the file still parses.
///
/// Cash transfers in/out of the SelfWealth account are NOT in this report —
/// they live in the Cash Report. The two parsers are deliberately scoped
/// apart to avoid cross-file dedupe.
struct SelfWealthMovementsParser: CSVParser, Sendable {

  let identifier = "selfwealth-movements"

  private static let requiredHeaders: Set<String> = [
    "trade date", "settlement date", "action", "reference", "code", "units",
  ]

  func recognizes(headers: [String]) -> Bool {
    let normalised = Set(headers.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
    return Self.requiredHeaders.isSubset(of: normalised)
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
    let tradeDate: Int
    let action: Int
    let reference: Int
    let code: Int
    let name: Int
    let units: Int
    let consideration: Int
    let brokerage: Int
  }

  /// Precondition: `recognizes(headers:)` has already returned true. Required
  /// columns are present; optional ones (consideration, brokerage, name) may
  /// not be — `findOptional` returns `-1` for those, and
  /// `SelfWealthCSVParsing.safe` coerces out-of-range reads to empty strings,
  /// so In/Out rows that lack those columns still parse cleanly.
  private func columnIndex(_ headers: [String]) throws -> Columns {
    let normalised = headers.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    func find(_ name: String) -> Int? { normalised.firstIndex(of: name) }
    func findOptional(_ name: String) -> Int { find(name) ?? -1 }
    guard let tradeDate = find("trade date"),
      let action = find("action"),
      let reference = find("reference"),
      let code = find("code"),
      let units = find("units")
    else {
      throw CSVParserError.headerMismatch
    }
    return Columns(
      tradeDate: tradeDate,
      action: action,
      reference: reference,
      code: code,
      name: findOptional("name"),
      units: units,
      consideration: findOptional("consideration"),
      brokerage: findOptional("brokerage"))
  }

  /// Common per-row state derived once and threaded through the action
  /// dispatch + builders, keeping `makeTradeRecord` / `makeTransferRecord`
  /// parameter lists small.
  private struct RowContext {
    let row: [String]
    let rowIndex: Int
    let columns: Columns
    let date: Date
    let code: String
    let units: Decimal
    let reference: String
    let rawDescription: String
  }

  private func parseDataRow(
    _ row: [String], columns: Columns, rowIndex: Int
  ) throws -> ParsedRecord {
    let action = SelfWealthCSVParsing.safe(row, columns.action)
      .trimmingCharacters(in: .whitespaces)
    let code = SelfWealthCSVParsing.safe(row, columns.code)
      .trimmingCharacters(in: .whitespaces)
    let name = SelfWealthCSVParsing.safe(row, columns.name)
      .trimmingCharacters(in: .whitespaces)
    let reference = SelfWealthCSVParsing.safe(row, columns.reference)
      .trimmingCharacters(in: .whitespaces)
    let unitsField = SelfWealthCSVParsing.safe(row, columns.units)

    guard
      let date = SelfWealthCSVParsing.parseDate(
        SelfWealthCSVParsing.safe(row, columns.tradeDate))
    else {
      throw CSVParserError.malformedRow(index: rowIndex, reason: "invalid trade date", row: row)
    }
    guard let units = SelfWealthCSVParsing.parseDecimal(unitsField) else {
      throw CSVParserError.malformedRow(
        index: rowIndex, reason: "invalid units: \(unitsField)", row: row)
    }

    let context = RowContext(
      row: row,
      rowIndex: rowIndex,
      columns: columns,
      date: date,
      code: code,
      units: units,
      reference: reference,
      rawDescription: "\(action) \(code) \(name)".trimmingCharacters(in: .whitespaces))

    switch action.lowercased() {
    case "buy": return try makeTradeRecord(context: context, isBuy: true)
    case "sell": return try makeTradeRecord(context: context, isBuy: false)
    case "in": return makeTransferRecord(context: context, isInbound: true)
    case "out": return makeTransferRecord(context: context, isInbound: false)
    default: return .skip(reason: "unsupported action: \(action)")
    }
  }

  private func makeTradeRecord(
    context: RowContext, isBuy: Bool
  ) throws -> ParsedRecord {
    let considerationField = SelfWealthCSVParsing.safe(context.row, context.columns.consideration)
    let brokerageField = SelfWealthCSVParsing.safe(context.row, context.columns.brokerage)
    guard let consideration = SelfWealthCSVParsing.parseDecimal(considerationField) else {
      throw CSVParserError.malformedRow(
        index: context.rowIndex,
        reason: "invalid consideration: \(considerationField)",
        row: context.row)
    }
    let brokerage = SelfWealthCSVParsing.parseDecimal(brokerageField) ?? 0
    let stockInstrument = Self.instrument(forASXCode: context.code)
    let cashAmount = isBuy ? -consideration : consideration

    var legs = [
      ParsedLeg(
        accountId: nil,
        instrument: .AUD,
        quantity: cashAmount,
        type: .trade,
        isInstrumentPlaceholder: true),
      ParsedLeg(
        accountId: nil,
        instrument: stockInstrument,
        quantity: isBuy ? context.units : -context.units,
        type: .trade,
        isInstrumentPlaceholder: false),
    ]
    if brokerage > 0 {
      legs.append(
        ParsedLeg(
          accountId: nil,
          instrument: .AUD,
          quantity: -brokerage,
          type: .expense,
          isInstrumentPlaceholder: true))
    }
    return .transaction(
      ParsedTransaction(
        date: context.date,
        legs: legs,
        rawRow: context.row,
        rawDescription: context.rawDescription,
        rawAmount: cashAmount,
        rawBalance: nil,
        bankReference: context.reference.isEmpty ? nil : context.reference))
  }

  /// SelfWealth's CSV stores the bare ASX code (e.g. `BHP`); the rest of
  /// the app uses the Yahoo-Finance-style `BHP.AX` ticker so imported legs
  /// share an `Instrument.id` with anything registered through the picker.
  private static func instrument(forASXCode code: String) -> Instrument {
    Instrument.stock(ticker: "\(code).AX", exchange: "ASX", name: code)
  }

  private func makeTransferRecord(
    context: RowContext, isInbound: Bool
  ) -> ParsedRecord {
    let signedUnits = isInbound ? context.units : -context.units
    let leg = ParsedLeg(
      accountId: nil,
      instrument: Self.instrument(forASXCode: context.code),
      quantity: signedUnits,
      type: isInbound ? .income : .expense,
      isInstrumentPlaceholder: false)
    return .transaction(
      ParsedTransaction(
        date: context.date,
        legs: [leg],
        rawRow: context.row,
        rawDescription: context.rawDescription,
        rawAmount: signedUnits,
        rawBalance: nil,
        bankReference: context.reference.isEmpty ? nil : context.reference))
  }
}
