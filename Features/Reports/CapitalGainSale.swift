import Foundation

struct CapitalGainSale: Identifiable, Hashable {
  let id: CapitalGainSaleIdentifier
  let instrument: Instrument
  let sellDate: Date
  var ownerLabel: String?
  let lots: [CapitalGainSaleLot]

  var quantity: Decimal { lots.reduce(0) { $0 + $1.quantity } }
  var proceeds: Decimal { lots.reduce(0) { $0 + $1.proceeds } }
  var costBasis: Decimal { lots.reduce(0) { $0 + $1.costBasis } }
  var gain: Decimal { proceeds - costBasis }
  var discountEligibleGain: Decimal { lots.reduce(0) { $0 + $1.discountEligibleGain } }
  var volumeWeightedCost: Decimal {
    guard quantity != 0 else { return 0 }
    return costBasis / quantity
  }
  var longTermQuantity: Decimal {
    lots.reduce(0) { total, lot in lot.event.isLongTerm ? total + lot.quantity : total }
  }
  var discountedPercent: Decimal {
    guard quantity != 0 else { return 0 }
    return longTermQuantity / quantity
  }

  static func stableAscendingOrder(_ lhs: CapitalGainSale, _ rhs: CapitalGainSale) -> Bool {
    if lhs.sellDate != rhs.sellDate { return lhs.sellDate < rhs.sellDate }
    if lhs.instrument.displayLabel != rhs.instrument.displayLabel {
      return lhs.instrument.displayLabel < rhs.instrument.displayLabel
    }
    if lhs.instrument.id != rhs.instrument.id { return lhs.instrument.id < rhs.instrument.id }
    if lhs.quantity != rhs.quantity { return lhs.quantity < rhs.quantity }
    if lhs.proceeds != rhs.proceeds { return lhs.proceeds < rhs.proceeds }
    if lhs.gain != rhs.gain { return lhs.gain < rhs.gain }
    return lhs.stableId < rhs.stableId
  }

  var stableId: String {
    switch id {
    case let .transaction(transactionId, instrumentId, taxOwnerId):
      return
        "transaction|\(transactionId.uuidString)|\(instrumentId)|\(taxOwnerId?.uuidString ?? "default")"
    case .fallback(let value):
      return "fallback|\(value)"
    }
  }
}
