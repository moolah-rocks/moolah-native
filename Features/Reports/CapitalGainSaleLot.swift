import Foundation

struct CapitalGainSaleLot: Identifiable, Hashable {
  let id: Int
  let event: CapitalGainEvent

  var acquiredDate: Date { event.acquiredDate }
  var quantity: Decimal { event.quantity }
  var costBasis: Decimal { event.costBasis }
  var proceeds: Decimal { event.proceeds }
  var gain: Decimal { event.gain }
  var discountEligibleGain: Decimal {
    event.isLongTerm && event.gain > 0 ? event.gain : 0
  }
}
