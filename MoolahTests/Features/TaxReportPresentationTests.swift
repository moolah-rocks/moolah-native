import Foundation
import Testing

@testable import Moolah

// Swift Testing's `@Test func foo()` is the documented idiom, and
// swift-format's `lineBreakBetweenDeclarationAttributes: false` keeps the
// attribute inline. Disable SwiftLint's `attributes` rule in this file so
// the formatter and the linter don't fight over the same layout.
// swiftlint:disable attributes type_body_length

@Suite("TaxReportPresentation")
struct TaxReportPresentationTests {
  @Test func currentFinancialYearTurnsOverInJuly() throws {
    let calendar = AustralianTaxCalendar.calendar
    let june = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 30)))
    let july = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 1)))

    #expect(TaxReportPresentation.currentFinancialYear(today: june, calendar: calendar) == 2026)
    #expect(TaxReportPresentation.currentFinancialYear(today: july, calendar: calendar) == 2027)
  }

  @Test func financialYearLabelUsesAustralianTaxYear() {
    #expect(TaxReportPresentation.financialYearLabel(2027) == "2026/27 financial year")
  }

  @Test func financialYearIntervalExcludesOnlyNextFinancialYear() throws {
    let calendar = AustralianTaxCalendar.calendar
    let interval = try #require(TaxReportPresentation.financialYearInterval(2026))
    let finalMillisecond = try #require(
      calendar.date(
        from: DateComponents(
          year: 2026, month: 6, day: 30, hour: 23, minute: 59, second: 59, nanosecond: 999_000_000))
    )
    let nextYearStart = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 7, day: 1)))

    #expect(interval.contains(finalMillisecond))
    #expect(!interval.contains(nextYearStart))
  }

  @Test func financialYearIntervalUsesAustralianTaxDate() throws {
    let interval = try #require(TaxReportPresentation.financialYearInterval(2026))
    let lateJuneInAustralia = try date(
      year: 2026,
      month: 6,
      day: 30,
      hour: 23,
      minute: 30,
      calendar: AustralianTaxCalendar.calendar)
    let julyStartInAustralia = try date(
      year: 2026,
      month: 7,
      day: 1,
      hour: 0,
      minute: 30,
      calendar: AustralianTaxCalendar.calendar)

    #expect(interval.contains(lateJuneInAustralia))
    #expect(!interval.contains(julyStartInAustralia))
  }

  @Test func financialYearEndDateUsesJuneThirty() throws {
    let calendar = AustralianTaxCalendar.calendar

    let endDate = try #require(TaxReportPresentation.financialYearEndDate(2026))

    #expect(calendar.component(.year, from: endDate) == 2026)
    #expect(calendar.component(.month, from: endDate) == 6)
    #expect(calendar.component(.day, from: endDate) == 30)
  }

  @Test func discountEligibilityStartsAfterAnniversaryDay() throws {
    let instrument = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let acquired = try date(year: 2024, month: 3, day: 1)
    let anniversaryDaySale = try date(year: 2025, month: 3, day: 1)
    let nextDaySale = try date(year: 2025, month: 3, day: 2)

    #expect(
      event(
        sourceTransactionId: nil,
        instrument: instrument,
        sellDate: anniversaryDaySale,
        acquiredDate: acquired,
        value: SaleEventValue(quantity: 1, costBasis: 10, proceeds: 20)
      ).isLongTerm == false)
    #expect(
      event(
        sourceTransactionId: nil,
        instrument: instrument,
        sellDate: nextDaySale,
        acquiredDate: acquired,
        value: SaleEventValue(quantity: 1, costBasis: 10, proceeds: 20)
      ).isLongTerm == true)
  }

  @Test func dateLabelUsesAustralianTaxDate() throws {
    let date = try #require(
      Calendar.utc.date(from: DateComponents(year: 2026, month: 6, day: 30, hour: 16)))
    let label = TaxReportPresentation.dateLabel(date, locale: Locale(identifier: "en_AU"))

    #expect(label.contains("1"))
    #expect(label.contains("Jul"))
    #expect(label.contains("2026"))
  }

  @Test func holdingsValuationDateUsesUtcNoonForAustralianCivilDate() throws {
    let observationDate = try date(year: 2026, month: 6, day: 30)

    let valuationDate = TaxReportPresentation.holdingsValuationDate(
      observationDate: observationDate)

    #expect(Calendar.utc.component(.year, from: valuationDate) == 2026)
    #expect(Calendar.utc.component(.month, from: valuationDate) == 6)
    #expect(Calendar.utc.component(.day, from: valuationDate) == 30)
    #expect(Calendar.utc.component(.hour, from: valuationDate) == 12)
  }

  @Test func gainAccessibilityTextNamesLossesPlainly() {
    let amount = InstrumentAmount(quantity: -120, instrument: .AUD)

    let text = TaxReportPresentation.gainAccessibilityText(for: amount)

    #expect(text.contains("loss of"))
    #expect(text.contains("120"))
  }

  @Test func errorDescriptionReplacesKnownInstrumentIdsWithDisplayNames() {
    let token = Instrument.crypto(
      chainId: 10,
      contractAddress: "0x21841eb46ccce03ebe57b4ee6eb547f31dfde152",
      symbol: "SPAM",
      name: "Spam Token",
      decimals: 18)
    let error = CryptoPriceError.noPriceAvailable(tokenId: token.id, date: "2026-07-06")

    let message = TaxReportPresentation.errorDescription(error, instruments: [token])

    #expect(message.contains("Spam Token (SPAM)"))
    #expect(!message.contains(token.id))
  }

  @Test func saleRowsGroupLotsBySourceTransaction() throws {
    let instrument = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let saleId = UUID()
    let saleDate = try date(year: 2026, month: 5, day: 1)
    let firstBuy = try date(year: 2025, month: 1, day: 1)
    let secondBuy = try date(year: 2026, month: 1, day: 1)

    let rows = TaxReportPresentation.saleRows(from: [
      event(
        sourceTransactionId: saleId,
        instrument: instrument,
        sellDate: saleDate,
        acquiredDate: firstBuy,
        value: SaleEventValue(quantity: 10, costBasis: 100, proceeds: 150)),
      event(
        sourceTransactionId: saleId,
        instrument: instrument,
        sellDate: saleDate,
        acquiredDate: secondBuy,
        value: SaleEventValue(quantity: 5, costBasis: 75, proceeds: 100)),
    ])

    #expect(rows.count == 1)
    #expect(rows[0].quantity == 15)
    #expect(rows[0].costBasis == 175)
    #expect(rows[0].proceeds == 250)
    #expect(rows[0].volumeWeightedCost == Decimal(175) / Decimal(15))
    #expect(rows[0].lots.map(\.acquiredDate) == [firstBuy, secondBuy])
  }

  @Test func saleRowsKeepSameDaySalesSeparate() throws {
    let instrument = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let saleDate = try date(year: 2026, month: 5, day: 1)
    let buyDate = try date(year: 2026, month: 1, day: 1)

    let rows = TaxReportPresentation.saleRows(from: [
      event(
        sourceTransactionId: UUID(),
        instrument: instrument,
        sellDate: saleDate,
        acquiredDate: buyDate,
        value: SaleEventValue(quantity: 10, costBasis: 100, proceeds: 150)),
      event(
        sourceTransactionId: UUID(),
        instrument: instrument,
        sellDate: saleDate,
        acquiredDate: buyDate,
        value: SaleEventValue(quantity: 20, costBasis: 200, proceeds: 260)),
    ])

    #expect(rows.count == 2)
  }

  @Test func saleRowsKeepDifferentInstrumentsInSameTransactionSeparate() throws {
    let saleId = UUID()
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let eth = Instrument.crypto(
      chainId: 1,
      contractAddress: nil,
      symbol: "ETH",
      name: "Ethereum",
      decimals: 18)
    let saleDate = try date(year: 2026, month: 5, day: 1)
    let buyDate = try date(year: 2025, month: 1, day: 1)

    let rows = TaxReportPresentation.saleRows(from: [
      event(
        sourceTransactionId: saleId,
        instrument: bhp,
        sellDate: saleDate,
        acquiredDate: buyDate,
        value: SaleEventValue(quantity: 10, costBasis: 100, proceeds: 150)),
      event(
        sourceTransactionId: saleId,
        instrument: eth,
        sellDate: saleDate,
        acquiredDate: buyDate,
        value: SaleEventValue(quantity: 1, costBasis: 2000, proceeds: 2100)),
    ])

    #expect(rows.count == 2)
    #expect(Set(rows.map(\.instrument)) == [bhp, eth])
  }

  @Test func saleRowsReportDiscountEligiblePositiveLongTermGains() throws {
    let instrument = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let saleId = UUID()
    let saleDate = try date(year: 2026, month: 5, day: 1)
    let longTermBuy = try date(year: 2024, month: 1, day: 1)
    let shortTermBuy = try date(year: 2026, month: 1, day: 1)

    let rows = TaxReportPresentation.saleRows(from: [
      event(
        sourceTransactionId: saleId,
        instrument: instrument,
        sellDate: saleDate,
        acquiredDate: longTermBuy,
        value: SaleEventValue(quantity: 10, costBasis: 100, proceeds: 200)),
      event(
        sourceTransactionId: saleId,
        instrument: instrument,
        sellDate: saleDate,
        acquiredDate: shortTermBuy,
        value: SaleEventValue(quantity: 5, costBasis: 100, proceeds: 75)),
    ])

    #expect(rows[0].gain == 75)
    #expect(rows[0].discountEligibleGain == 100)
    #expect(rows[0].discountedPercent == Decimal(10) / Decimal(15))
  }

  @Test func saleRowsDoNotTreatLongTermLossesAsDiscountEligible() throws {
    let instrument = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let saleId = UUID()
    let saleDate = try date(year: 2026, month: 5, day: 1)
    let longTermBuy = try date(year: 2024, month: 1, day: 1)

    let rows = TaxReportPresentation.saleRows(from: [
      event(
        sourceTransactionId: saleId,
        instrument: instrument,
        sellDate: saleDate,
        acquiredDate: longTermBuy,
        value: SaleEventValue(quantity: 10, costBasis: 200, proceeds: 100))
    ])

    #expect(rows[0].gain == -100)
    #expect(rows[0].discountEligibleGain == 0)
    #expect(rows[0].discountedPercent == 1)
  }

  @Test func saleRowsExcludeZeroValueEvents() throws {
    let instrument = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let saleDate = try date(year: 2026, month: 5, day: 1)
    let buyDate = try date(year: 2025, month: 1, day: 1)

    let rows = TaxReportPresentation.saleRows(from: [
      event(
        sourceTransactionId: UUID(),
        instrument: instrument,
        sellDate: saleDate,
        acquiredDate: buyDate,
        value: SaleEventValue(quantity: 0, costBasis: 0, proceeds: 0)),
      event(
        sourceTransactionId: UUID(),
        instrument: instrument,
        sellDate: saleDate,
        acquiredDate: buyDate,
        value: SaleEventValue(quantity: 10, costBasis: 100, proceeds: 150)),
    ])

    #expect(rows.count == 1)
    #expect(rows[0].quantity == 10)
  }

  private func event(
    sourceTransactionId: UUID?,
    instrument: Instrument,
    sellDate: Date,
    acquiredDate: Date,
    value: SaleEventValue
  ) -> CapitalGainEvent {
    let holdingDays =
      Calendar.utc.dateComponents([.day], from: acquiredDate, to: sellDate).day ?? 0
    return CapitalGainEvent(
      sourceTransactionId: sourceTransactionId,
      instrument: instrument,
      sellDate: sellDate,
      acquiredDate: acquiredDate,
      quantity: value.quantity,
      costBasis: value.costBasis,
      proceeds: value.proceeds,
      holdingDays: holdingDays)
  }

  private func date(year: Int, month: Int, day: Int) throws -> Date {
    try #require(
      AustralianTaxCalendar.calendar.date(from: DateComponents(year: year, month: month, day: day)))
  }

  private func date(
    year: Int,
    month: Int,
    day: Int,
    hour: Int,
    minute: Int = 0,
    calendar: Calendar
  ) throws -> Date {
    try #require(
      calendar.date(
        from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)))
  }
}

private struct SaleEventValue {
  let quantity: Decimal
  let costBasis: Decimal
  let proceeds: Decimal
}

// swiftlint:enable attributes type_body_length
