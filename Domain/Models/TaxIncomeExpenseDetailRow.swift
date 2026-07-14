import Foundation

struct TaxIncomeExpenseDetailRow {
  let transactionId: UUID
  let ownerId: UUID
  let categoryId: UUID
  let instrument: Instrument
  let day: Date?
  let dayLabel: String
  let amount: InstrumentAmount?
  let isSplitAcrossTaxOwners: Bool
  var hasUnavailableData = false

  init(
    transactionId: UUID,
    ownerId: UUID,
    categoryId: UUID,
    instrument: Instrument,
    day: Date?,
    dayLabel: String? = nil,
    amount: InstrumentAmount?,
    isSplitAcrossTaxOwners: Bool = false,
    hasUnavailableData: Bool = false
  ) {
    self.transactionId = transactionId
    self.ownerId = ownerId
    self.categoryId = categoryId
    self.instrument = instrument
    self.day = day
    self.dayLabel =
      dayLabel ?? day.map { String($0.timeIntervalSinceReferenceDate) }
      ?? "Date unavailable"
    self.amount = amount
    self.isSplitAcrossTaxOwners = isSplitAcrossTaxOwners
    self.hasUnavailableData = hasUnavailableData
  }
}

extension TaxIncomeExpenseDetailRow: Sendable {}

extension TaxIncomeExpenseDetailRow: Identifiable {
  var id: String {
    [
      transactionId.uuidString,
      ownerId.uuidString,
      categoryId.uuidString,
      instrument.id,
      dayLabel,
    ].joined(separator: ":")
  }
}

extension TaxIncomeExpenseDetailRow: Hashable {}
