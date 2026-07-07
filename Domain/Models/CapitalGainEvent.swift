import Foundation

/// A realized capital gain or loss from selling (part of) a lot.
struct CapitalGainEvent: Sendable, Hashable {
  let sourceTransactionId: UUID?
  let instrument: Instrument
  let sellDate: Date
  let acquiredDate: Date
  let quantity: Decimal
  let costBasis: Decimal
  let proceeds: Decimal
  let holdingDays: Int

  /// Gain or loss. Positive = gain, negative = loss.
  var gain: Decimal { proceeds - costBasis }

  var isReportableSale: Bool {
    quantity != 0 && (proceeds != 0 || costBasis != 0)
  }

  /// Australian CGT discount eligibility. The ATO rule is calendar based:
  /// exclude both the acquisition day and the CGT event day, so the disposal
  /// day must be after the 12-month anniversary of the acquisition day.
  var isLongTerm: Bool {
    let calendar = AustralianTaxCalendar.calendar
    let acquiredDay = calendar.startOfDay(for: acquiredDate)
    let disposalDay = calendar.startOfDay(for: sellDate)
    guard let anniversary = calendar.date(byAdding: .year, value: 1, to: acquiredDay) else {
      return false
    }
    return disposalDay > anniversary
  }
}
