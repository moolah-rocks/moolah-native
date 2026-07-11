import Foundation

enum TaxReportPresentation {
  static func currentFinancialYear(
    today: Date = Date(),
    calendar: Calendar = AustralianTaxCalendar.calendar
  ) -> Int {
    let year = calendar.component(.year, from: today)
    let month = calendar.component(.month, from: today)
    return month >= 7 ? year + 1 : year
  }

  static func financialYears(
    around today: Date = Date(),
    calendar: Calendar = AustralianTaxCalendar.calendar,
    lookback: Int = 5
  ) -> [Int] {
    let current = currentFinancialYear(today: today, calendar: calendar)
    return (0...lookback).map { current - $0 }
  }

  static func financialYearLabel(_ year: Int) -> String {
    "\(year - 1)/\(String(format: "%02d", year % 100)) financial year"
  }

  static func financialYearInterval(
    _ year: Int,
    calendar: Calendar = AustralianTaxCalendar.calendar
  ) -> Range<Date>? {
    guard
      let start = calendar.date(from: DateComponents(year: year - 1, month: 7, day: 1)),
      let nextYearStart = calendar.date(from: DateComponents(year: year, month: 7, day: 1))
    else { return nil }
    return start..<nextYearStart
  }

  static func financialYearEndDate(
    _ year: Int,
    calendar: Calendar = AustralianTaxCalendar.calendar
  ) -> Date? {
    calendar.date(from: DateComponents(year: year, month: 6, day: 30))
  }

  static func holdingsObservationDate(
    financialYear: Int,
    today: Date = Date(),
    calendar: Calendar = AustralianTaxCalendar.calendar
  ) -> Date {
    guard let financialYearEnd = financialYearEndDate(financialYear, calendar: calendar) else {
      return today
    }
    let todayDay = calendar.startOfDay(for: today)
    return min(financialYearEnd, todayDay)
  }

  static func holdingsLedgerCutoffDate(
    financialYear: Int,
    observationDate: Date,
    calendar: Calendar = AustralianTaxCalendar.calendar
  ) -> Date? {
    guard
      let financialYearEnd = financialYearEndDate(financialYear, calendar: calendar),
      let financialYearInterval = financialYearInterval(financialYear, calendar: calendar)
    else { return nil }
    if calendar.startOfDay(for: observationDate) < financialYearEnd {
      return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: observationDate))
    }
    return financialYearInterval.upperBound
  }

  static func holdingsValuationDate(
    observationDate: Date,
    calendar: Calendar = AustralianTaxCalendar.calendar
  ) -> Date {
    let components = calendar.dateComponents([.year, .month, .day], from: observationDate)
    return Calendar.utc.date(
      from: DateComponents(
        timeZone: .utc,
        year: components.year,
        month: components.month,
        day: components.day,
        hour: 12)) ?? observationDate
  }

  static func holdingPeriodLabel(for event: CapitalGainEvent) -> String {
    event.isLongTerm ? "Held over 12 months" : "Held 12 months or less"
  }

  static func dateLabel(_ date: Date, locale: Locale = .current) -> String {
    let formatter = DateFormatter()
    formatter.calendar = AustralianTaxCalendar.calendar
    formatter.timeZone = AustralianTaxCalendar.timeZone
    formatter.locale = locale
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter.string(from: date)
  }

  static func errorMessage(_ error: any Error) -> String {
    error.localizedDescription
  }

  static func saleRows(
    from events: [CapitalGainEvent],
    taxOwnerNames: [UUID: String] = [:],
    defaultTaxOwnerId: UUID? = nil,
    includeOwnerLabels: Bool = false
  ) -> [CapitalGainSale] {
    let indexed = events.filter(\.isReportableSale).enumerated()
    let grouped = Dictionary(grouping: indexed) { _, event in
      saleGroupId(for: event)
    }
    return grouped.values.map { group in
      let sorted = group.sorted {
        if $0.element.acquiredDate != $1.element.acquiredDate {
          return $0.element.acquiredDate < $1.element.acquiredDate
        }
        return $0.offset < $1.offset
      }
      let first = sorted[0].element
      return CapitalGainSale(
        id: saleGroupId(for: first),
        instrument: first.instrument,
        sellDate: first.sellDate,
        ownerLabel: ownerLabel(
          for: first.taxOwnerId,
          taxOwnerNames: taxOwnerNames,
          defaultTaxOwnerId: defaultTaxOwnerId,
          includeOwnerLabels: includeOwnerLabels),
        lots: sorted.map { CapitalGainSaleLot(id: $0.offset, event: $0.element) })
    }.sorted(by: CapitalGainSale.stableAscendingOrder)
  }

  private static func ownerLabel(
    for taxOwnerId: UUID?,
    taxOwnerNames: [UUID: String],
    defaultTaxOwnerId: UUID?,
    includeOwnerLabels: Bool
  ) -> String? {
    guard includeOwnerLabels else { return nil }
    guard let taxOwnerId else {
      if let defaultTaxOwnerId, let name = taxOwnerNames[defaultTaxOwnerId], !name.isEmpty {
        return name
      }
      return "Default owner"
    }
    if let name = taxOwnerNames[taxOwnerId], !name.isEmpty { return name }
    if taxOwnerId == defaultTaxOwnerId { return "Default owner" }
    return "Owner \(taxOwnerId.uuidString.prefix(8))"
  }

  static func financialYearEndHoldings(
    from profitLoss: [InstrumentProfitLoss],
    profileInstrument: Instrument
  ) -> FinancialYearEndHoldingsPresentation {
    let rows =
      profitLoss
      .filter { $0.currentQuantity != 0 }
      .sorted {
        if $0.unrealizedGain != $1.unrealizedGain {
          return $0.unrealizedGain.magnitude > $1.unrealizedGain.magnitude
        }
        return $0.instrument.displayLabel < $1.instrument.displayLabel
      }
    return FinancialYearEndHoldingsPresentation(
      rows: rows,
      unrealizedTotal: InstrumentAmount(
        quantity: rows.reduce(Decimal(0)) { $0 + $1.unrealizedGain },
        instrument: profileInstrument))
  }

  private static func saleGroupId(for event: CapitalGainEvent) -> CapitalGainSaleIdentifier {
    if let sourceTransactionId = event.sourceTransactionId {
      return .transaction(
        sourceTransactionId,
        instrumentId: event.instrument.id,
        taxOwnerId: event.taxOwnerId)
    }
    return .fallback(
      [
        event.instrument.id,
        event.taxOwnerId?.uuidString ?? "default",
        String(event.sellDate.timeIntervalSinceReferenceDate),
        String(event.acquiredDate.timeIntervalSinceReferenceDate),
        "\(event.quantity)",
        "\(event.proceeds)",
      ].joined(separator: "|"))
  }

  static func gainAccessibilityText(for amount: InstrumentAmount) -> String {
    if amount.quantity < 0 {
      return "loss of \((-amount).formatted)"
    }
    return "gain of \(amount.formatted)"
  }

  static func errorDescription(_ error: Error, instruments: [Instrument]) -> String {
    instruments.reduce(error.localizedDescription) { message, instrument in
      message.replacingOccurrences(of: instrument.id, with: instrument.pickerLabel)
    }
  }
}
