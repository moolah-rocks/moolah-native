import Foundation

struct TaxReportExportInput {
  let financialYear: Int
  let holdingsDate: Date
  let profileInstrument: Instrument
  let summary: CapitalGainsSummary?
  let events: [CapitalGainEvent]
  let capitalGainsHasUnavailableData: Bool
  let capitalGainsUnavailableInstruments: [Instrument]
  let taxIncomeExpenseSummaries: [TaxIncomeExpenseSummary]
  let taxIncomeExpenseRollup: TaxIncomeExpenseSummary?
  let taxOwnerNames: [UUID: String]
  let profitLoss: [InstrumentProfitLoss]
  let profitLossHasUnavailableData: Bool
  let profitLossUnavailableInstruments: [Instrument]
  let defaultTaxOwnerId: UUID
}

enum TaxReportExportBuilder {
  static func csv(for input: TaxReportExportInput) -> String {
    var writer = CSVWriter()
    appendMetadata(input, to: &writer)
    appendSummaryRows(input, to: &writer)
    appendSalesRows(input, to: &writer)
    appendHoldingsRows(input, to: &writer)
    return writer.output
  }
}

extension TaxReportExportBuilder {
  private static func appendMetadata(_ input: TaxReportExportInput, to writer: inout CSVWriter) {
    writer.append(["Financial year", TaxReportPresentation.financialYearLabel(input.financialYear)])
    writer.append(["Holdings date", dateLabel(input.holdingsDate)])
    writer.append([])
  }

  private static func appendSummaryRows(_ input: TaxReportExportInput, to writer: inout CSVWriter) {
    writer.append(["Scope", "Owner", "Metric", "Amount", "Instrument", "Unavailable"])
    appendSummaryRows(context: allOwnerSummaryContext(input), to: &writer)
    let summariesByOwner = Dictionary(
      uniqueKeysWithValues: input.taxIncomeExpenseSummaries.map {
        ($0.ownerId, $0)
      })
    for ownerId in sortedSummaryOwnerIds(input) {
      appendSummaryRows(
        context: ownerSummaryContext(
          ownerId: ownerId,
          incomeExpenseSummary: summariesByOwner[ownerId],
          input: input),
        to: &writer)
    }
    writer.append([])
  }

  private static func allOwnerSummaryContext(_ input: TaxReportExportInput) -> SummaryRowContext {
    SummaryRowContext(
      scope: "All owners",
      owner: "All owners",
      incomeExpenseSummary: input.taxIncomeExpenseRollup,
      capitalGainsSummary: input.summary,
      capitalGainsUnavailable: input.capitalGainsHasUnavailableData,
      instrument: input.profileInstrument)
  }

  private static func ownerSummaryContext(
    ownerId: UUID,
    incomeExpenseSummary: TaxIncomeExpenseSummary?,
    input: TaxReportExportInput
  ) -> SummaryRowContext {
    SummaryRowContext(
      scope: "Owner",
      owner: ownerName(ownerId, in: input),
      incomeExpenseSummary: incomeExpenseSummary,
      capitalGainsSummary: capitalGainsSummary(ownerId: ownerId, input: input),
      capitalGainsUnavailable: false,
      instrument: input.profileInstrument)
  }

  private static func appendSummaryRows(
    context: SummaryRowContext,
    to writer: inout CSVWriter
  ) {
    appendAmountRow(
      metric: "Taxable income", amount: context.taxableIncome, context: context, to: &writer)
    appendAmountRow(
      metric: "Deductible expenses",
      amount: context.deductibleExpenses,
      context: context,
      to: &writer)
    appendAmountRow(
      metric: "Net taxable income",
      amount: context.netTaxableIncome,
      context: context,
      to: &writer)
    appendDecimalRow(
      metric: "Net capital gain",
      amount: context.capitalGainsSummary?.netCapitalGain,
      context: context.capitalGainsContext,
      to: &writer)
  }

  private static func appendAmountRow(
    metric: String,
    amount: InstrumentAmount?,
    context: SummaryRowContext,
    to writer: inout CSVWriter
  ) {
    appendDecimalRow(
      metric: metric,
      amount: context.incomeExpenseUnavailable ? nil : amount?.quantity,
      context: context.amountContext(amount),
      to: &writer)
  }

  private static func appendDecimalRow(
    metric: String,
    amount: Decimal?,
    context: AmountRowContext,
    to writer: inout CSVWriter
  ) {
    writer.append([
      context.scope,
      context.owner,
      metric,
      context.unavailable ? "" : amount.map(decimalLabel) ?? "",
      instrumentExportLabel(context.instrument),
      context.unavailable ? "true" : "false",
    ])
  }
}

extension TaxReportExportBuilder {
  private static func appendSalesRows(_ input: TaxReportExportInput, to writer: inout CSVWriter) {
    writer.append([
      "Owner",
      "Sell date",
      "Acquired date",
      "Instrument",
      "Quantity",
      "Proceeds",
      "Cost basis",
      "Gain",
      "Holding period",
      "Source transaction ID",
    ])
    for event in input.events.filter(\.isReportableSale).sorted(by: saleSort) {
      appendSaleEvent(event, input: input, to: &writer)
    }
    for instrument in sortedInstruments(input.capitalGainsUnavailableInstruments) {
      writer.append(["Sales", "All owners", instrument.displayLabel, "Missing price"])
    }
    writer.append([])
  }

  private static func appendSaleEvent(
    _ event: CapitalGainEvent,
    input: TaxReportExportInput,
    to writer: inout CSVWriter
  ) {
    writer.append([
      ownerName(event.taxOwnerId, in: input),
      dateLabel(event.sellDate),
      dateLabel(event.acquiredDate),
      event.instrument.displayLabel,
      decimalLabel(event.quantity),
      decimalLabel(event.proceeds),
      decimalLabel(event.costBasis),
      decimalLabel(event.gain),
      TaxReportPresentation.holdingPeriodLabel(for: event),
      event.sourceTransactionId?.uuidString ?? "",
    ])
  }

  private static func appendHoldingsRows(_ input: TaxReportExportInput, to writer: inout CSVWriter)
  {
    writer.append([
      "Section",
      "Owner",
      "Instrument",
      "Current quantity",
      "Total invested",
      "Current value",
      "Realized gain",
      "Unrealized gain",
      "Total gain",
      "Valuation instrument",
    ])
    for row in input.profitLoss.sorted(by: holdingSort) where row.currentQuantity != 0 {
      appendHolding(row, profileInstrument: input.profileInstrument, to: &writer)
    }
    for instrument in sortedInstruments(input.profitLossUnavailableInstruments) {
      writer.append(["Holdings", "All owners", instrument.displayLabel, "Missing price"])
    }
  }

  private static func appendHolding(
    _ row: InstrumentProfitLoss,
    profileInstrument: Instrument,
    to writer: inout CSVWriter
  ) {
    writer.append([
      "Holdings",
      "All owners",
      row.instrument.displayLabel,
      decimalLabel(row.currentQuantity),
      decimalLabel(row.totalInvested),
      decimalLabel(row.currentValue),
      decimalLabel(row.realizedGain),
      decimalLabel(row.unrealizedGain),
      decimalLabel(row.totalGain),
      instrumentExportLabel(profileInstrument),
    ])
  }
}

extension TaxReportExportBuilder {
  private static func sortedSummaryOwnerIds(_ input: TaxReportExportInput) -> [UUID] {
    let incomeExpenseOwnerIds = input.taxIncomeExpenseSummaries.map(\.ownerId)
    let capitalGainOwnerIds = input.events.compactMap { event in
      event.isReportableSale ? event.taxOwnerId : nil
    }
    return Set(incomeExpenseOwnerIds + capitalGainOwnerIds).sorted {
      let lhs = ownerName($0, in: input)
      let rhs = ownerName($1, in: input)
      if lhs != rhs { return lhs.localizedStandardCompare(rhs) == .orderedAscending }
      return $0.uuidString < $1.uuidString
    }
  }

  private static func capitalGainsSummary(
    ownerId: UUID,
    input: TaxReportExportInput
  ) -> CapitalGainsSummary? {
    let reportableEvents = input.events.filter { $0.taxOwnerId == ownerId && $0.isReportableSale }
    guard !reportableEvents.isEmpty else { return nil }
    let saleCount = TaxReportPresentation.saleRows(from: reportableEvents).count
    let shortTermEvents = reportableEvents.filter { !$0.isLongTerm }
    let longTermEvents = reportableEvents.filter(\.isLongTerm)
    return CapitalGainsSummary(
      shortTermGain: shortTermEvents.reduce(Decimal(0)) { $0 + $1.gain },
      longTermGain: longTermEvents.reduce(Decimal(0)) { $0 + $1.gain },
      totalGain: reportableEvents.reduce(Decimal(0)) { $0 + $1.gain },
      eventCount: saleCount,
      shortTermCapitalGains: shortTermEvents.reduce(Decimal(0)) { $0 + max(0, $1.gain) },
      longTermCapitalGains: longTermEvents.reduce(Decimal(0)) { $0 + max(0, $1.gain) },
      capitalLosses: -reportableEvents.reduce(Decimal(0)) { $0 + min(0, $1.gain) })
  }

  private static func ownerName(_ ownerId: UUID?, in input: TaxReportExportInput) -> String {
    guard let ownerId else { return ownerName(input.defaultTaxOwnerId, in: input) }
    if let name = input.taxOwnerNames[ownerId], !name.isEmpty { return name }
    if ownerId == input.defaultTaxOwnerId { return "Default owner" }
    return "Owner \(ownerId.uuidString.prefix(8))"
  }
}

extension TaxReportExportBuilder {
  private static func saleSort(_ lhs: CapitalGainEvent, _ rhs: CapitalGainEvent) -> Bool {
    if lhs.sellDate != rhs.sellDate { return lhs.sellDate < rhs.sellDate }
    if lhs.acquiredDate != rhs.acquiredDate { return lhs.acquiredDate < rhs.acquiredDate }
    if lhs.instrument.displayLabel != rhs.instrument.displayLabel {
      return lhs.instrument.displayLabel < rhs.instrument.displayLabel
    }
    return (lhs.sourceTransactionId?.uuidString ?? "") < (rhs.sourceTransactionId?.uuidString ?? "")
  }

  private static func holdingSort(_ lhs: InstrumentProfitLoss, _ rhs: InstrumentProfitLoss) -> Bool
  {
    lhs.instrument.displayLabel < rhs.instrument.displayLabel
  }

  private static func sortedInstruments(_ instruments: [Instrument]) -> [Instrument] {
    instruments.sorted {
      if $0.displayLabel != $1.displayLabel { return $0.displayLabel < $1.displayLabel }
      return $0.id < $1.id
    }
  }

  private static func instrumentExportLabel(_ instrument: Instrument) -> String {
    switch instrument.kind {
    case .fiatCurrency:
      return instrument.id
    case .stock, .cryptoToken:
      return instrument.displayLabel
    }
  }

  private static func dateLabel(_ date: Date) -> String {
    let components = AustralianTaxCalendar.calendar.dateComponents(
      [.year, .month, .day],
      from: date)
    return String(
      format: "%04d-%02d-%02d",
      components.year ?? 0,
      components.month ?? 0,
      components.day ?? 0)
  }

  private static func decimalLabel(_ decimal: Decimal) -> String {
    NSDecimalNumber(decimal: decimal).stringValue
  }
}

private struct SummaryRowContext {
  let scope: String
  let owner: String
  let incomeExpenseSummary: TaxIncomeExpenseSummary?
  let capitalGainsSummary: CapitalGainsSummary?
  let capitalGainsUnavailable: Bool
  let instrument: Instrument

  var taxableIncome: InstrumentAmount? { incomeExpenseSummary?.taxableIncome }
  var deductibleExpenses: InstrumentAmount? { incomeExpenseSummary?.deductibleExpenses }
  var netTaxableIncome: InstrumentAmount? { incomeExpenseSummary?.netTaxableIncome }
  var incomeExpenseUnavailable: Bool { incomeExpenseSummary?.hasUnavailableData ?? false }

  var capitalGainsContext: AmountRowContext {
    AmountRowContext(
      scope: scope,
      owner: owner,
      unavailable: capitalGainsUnavailable,
      instrument: instrument)
  }

  func amountContext(_ amount: InstrumentAmount?) -> AmountRowContext {
    AmountRowContext(
      scope: scope,
      owner: owner,
      unavailable: incomeExpenseUnavailable,
      instrument: amount?.instrument ?? instrument)
  }
}

private struct AmountRowContext {
  let scope: String
  let owner: String
  let unavailable: Bool
  let instrument: Instrument
}

private struct CSVWriter {
  private var lines: [String] = []

  var output: String { lines.joined(separator: "\n") + "\n" }

  mutating func append(_ fields: [String]) {
    lines.append(fields.map(escape).joined(separator: ","))
  }

  private func escape(_ field: String) -> String {
    guard field.contains(",") || field.contains("\"") || field.contains("\n") else {
      return field
    }
    return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
  }
}
