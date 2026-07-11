import Foundation

struct TaxIncomeExpenseDetailRow: Sendable, Identifiable, Hashable {
  var id: String {
    [
      ownerId.uuidString,
      categoryId.uuidString,
      instrument.id,
      dayLabel,
    ].joined(separator: ":")
  }

  let ownerId: UUID
  let categoryId: UUID
  let instrument: Instrument
  let day: Date?
  let dayLabel: String
  let amount: InstrumentAmount?
  var hasUnavailableData = false

  init(
    ownerId: UUID,
    categoryId: UUID,
    instrument: Instrument,
    day: Date?,
    dayLabel: String? = nil,
    amount: InstrumentAmount?,
    hasUnavailableData: Bool = false
  ) {
    self.ownerId = ownerId
    self.categoryId = categoryId
    self.instrument = instrument
    self.day = day
    self.dayLabel =
      dayLabel ?? day.map { String($0.timeIntervalSinceReferenceDate) }
      ?? "Date unavailable"
    self.amount = amount
    self.hasUnavailableData = hasUnavailableData
  }
}
