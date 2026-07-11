// Tax report CSV output has one row-building surface; splitting the helpers would duplicate column-order invariants.
// swiftlint:disable file_length

import Foundation

struct TaxReportExportInput {
  let financialYear: Int
  let holdingsDate: Date
  let profileInstrument: Instrument
  var selectedOwnerId: UUID?
  let summary: CapitalGainsSummary?
  let events: [CapitalGainEvent]
  let capitalGainsHasUnavailableData: Bool
  let capitalGainsUnavailableInstruments: [Instrument]
  var capitalGainsHasUnavailableDataByOwner: [UUID: Bool] = [:]
  var ownerUnavailableCapitalGainsInstruments: [UUID: [Instrument]] = [:]
  let taxIncomeExpenseSummaries: [TaxIncomeExpenseSummary]
  let taxIncomeExpenseRollup: TaxIncomeExpenseSummary?
  let taxOwnerNames: [UUID: String]
  let taxOwnerKinds: [UUID: TaxOwnerKind]
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
  private static func taxIncomeExpenseRollup(
    from summaries: [TaxIncomeExpenseSummary],
    instrument: Instrument
  ) -> TaxIncomeExpenseSummary? {
    guard let ownerId = summaries.first?.ownerId else { return nil }
    let zero = InstrumentAmount.zero(instrument: instrument)
    let income = summaries.reduce(zero) { $0 + $1.taxableIncome }
    let deductions = summaries.reduce(zero) { $0 + $1.deductibleExpenses }
    return TaxIncomeExpenseSummary(
      ownerId: ownerId,
      taxableIncome: income,
      deductibleExpenses: deductions,
      hasUnavailableData: summaries.contains { $0.hasUnavailableData })
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
    if let selectedOwnerId = input.selectedOwnerId {
      appendSummaryRows(
        context: selectedOwnerSummaryContext(ownerId: selectedOwnerId, input: input),
        to: &writer)
    } else {
      appendSummaryRows(context: allOwnerSummaryContext(input), to: &writer)
      let summariesByOwner = Dictionary(
        grouping: input.taxIncomeExpenseSummaries,
        by: \.ownerId
      ).mapValues {
        taxIncomeExpenseRollup(from: $0, instrument: input.profileInstrument)
      }
      for ownerId in sortedSummaryOwnerIds(input) {
        appendSummaryRows(
          context: ownerSummaryContext(
            ownerId: ownerId,
            incomeExpenseSummary: summariesByOwner[ownerId] ?? nil,
            input: input),
          to: &writer)
      }
    }
    writer.append([])
  }

  private static func allOwnerSummaryContext(_ input: TaxReportExportInput) -> SummaryRowContext {
    SummaryRowContext(
      scope: "All owners",
      owner: "All owners",
      incomeExpenseSummary: input.taxIncomeExpenseRollup,
      capitalGainsSummary: input.summary,
      ownerKind: nil,
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
      ownerKind: input.taxOwnerKinds[ownerId] ?? .individual,
      capitalGainsUnavailable: input.capitalGainsHasUnavailableDataByOwner[ownerId]
        ?? input.capitalGainsHasUnavailableData,
      instrument: input.profileInstrument)
  }

  private static func selectedOwnerSummaryContext(
    ownerId: UUID,
    input: TaxReportExportInput
  ) -> SummaryRowContext {
    SummaryRowContext(
      scope: "Owner",
      owner: ownerName(ownerId, in: input),
      incomeExpenseSummary: input.taxIncomeExpenseRollup,
      capitalGainsSummary: input.summary ?? capitalGainsSummary(ownerId: ownerId, input: input),
      ownerKind: input.taxOwnerKinds[ownerId] ?? .individual,
      capitalGainsUnavailable: input.capitalGainsHasUnavailableData,
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
    appendCapitalGainsRows(context: context, to: &writer)
  }

  private static func appendCapitalGainsRows(
    context: SummaryRowContext,
    to writer: inout CSVWriter
  ) {
    guard context.ownerKind != .trust else {
      let values = context.capitalGainsSummary?.asTaxAdjustmentValues(currency: context.instrument)
      appendDecimalRow(
        metric: "Short-term capital gains",
        amount: values?.shortTerm.quantity,
        context: context.capitalGainsContext,
        to: &writer)
      appendDecimalRow(
        metric: "Long-term capital gains",
        amount: values?.longTerm.quantity,
        context: context.capitalGainsContext,
        to: &writer)
      appendDecimalRow(
        metric: "Capital losses",
        amount: values?.losses.quantity,
        context: context.capitalGainsContext,
        to: &writer)
      return
    }
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
    appendUnavailableSaleRows(input, to: &writer)
    writer.append([])
  }

  private static func appendUnavailableSaleRows(
    _ input: TaxReportExportInput,
    to writer: inout CSVWriter
  ) {
    let unavailableOwnerLabel =
      input.selectedOwnerId.map { ownerName($0, in: input) } ?? "All owners"
    for instrument in sortedInstruments(input.capitalGainsUnavailableInstruments) {
      writer.append(["Sales", unavailableOwnerLabel, instrument.displayLabel, "Missing price"])
    }
    guard input.selectedOwnerId == nil else { return }
    for ownerId in sortedOwnerUnavailableCapitalGainsInstrumentIds(input) {
      let ownerLabel = ownerName(ownerId, in: input)
      for instrument in sortedInstruments(
        input.ownerUnavailableCapitalGainsInstruments[ownerId] ?? [])
      {
        writer.append(["Sales", ownerLabel, instrument.displayLabel, "Missing price"])
      }
    }
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
    let ownerLabel = input.selectedOwnerId.map { ownerName($0, in: input) } ?? "All owners"
    for row in input.profitLoss.sorted(by: holdingSort) where row.currentQuantity != 0 {
      appendHolding(
        row, ownerLabel: ownerLabel, profileInstrument: input.profileInstrument, to: &writer)
    }
    for instrument in sortedInstruments(input.profitLossUnavailableInstruments) {
      writer.append(["Holdings", ownerLabel, instrument.displayLabel, "Missing price"])
    }
  }

  private static func appendHolding(
    _ row: InstrumentProfitLoss,
    ownerLabel: String,
    profileInstrument: Instrument,
    to writer: inout CSVWriter
  ) {
    writer.append([
      "Holdings",
      ownerLabel,
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
    activeOwnerIds(input).sorted {
      let lhs = ownerName($0, in: input)
      let rhs = ownerName($1, in: input)
      if lhs != rhs { return lhs.localizedStandardCompare(rhs) == .orderedAscending }
      return $0.uuidString < $1.uuidString
    }
  }

  private static func sortedOwnerUnavailableCapitalGainsInstrumentIds(
    _ input: TaxReportExportInput
  ) -> [UUID] {
    input.ownerUnavailableCapitalGainsInstruments.keys.sorted {
      let lhs = ownerName($0, in: input)
      let rhs = ownerName($1, in: input)
      if lhs != rhs { return lhs.localizedStandardCompare(rhs) == .orderedAscending }
      return $0.uuidString < $1.uuidString
    }
  }

  private static func activeOwnerIds(_ input: TaxReportExportInput) -> Set<UUID> {
    let incomeExpenseOwnerIds = input.taxIncomeExpenseSummaries.map(\.ownerId)
    let capitalGainOwnerIds = input.events.compactMap { event in
      event.isReportableSale ? event.taxOwnerId ?? input.defaultTaxOwnerId : nil
    }
    let unavailableCapitalGainOwnerIds =
      input.capitalGainsHasUnavailableDataByOwner.compactMap { ownerId, hasUnavailableData in
        hasUnavailableData ? ownerId : nil
      }
    return Set(
      incomeExpenseOwnerIds + capitalGainOwnerIds + unavailableCapitalGainOwnerIds
        + input.ownerUnavailableCapitalGainsInstruments.keys)
  }

  private static func capitalGainsSummary(
    ownerId: UUID,
    input: TaxReportExportInput
  ) -> CapitalGainsSummary? {
    let reportableEvents = input.events.filter {
      ($0.taxOwnerId ?? input.defaultTaxOwnerId) == ownerId && $0.isReportableSale
    }
    guard !reportableEvents.isEmpty else { return nil }
    return ReportingStore.capitalGainsSummary(from: reportableEvents)
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
  let ownerKind: TaxOwnerKind?
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
