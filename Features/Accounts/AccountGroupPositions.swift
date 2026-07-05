import Foundation

/// Sums per-instrument quantities across the supplied account ids,
/// preserving first-seen order. Members holding the same instrument
/// coalesce to one row; multi-instrument groups expose a row per
/// instrument. Pure (no actor isolation) so it can be unit-tested
/// without instantiating the SwiftUI view.
func aggregatedGroupPositions(
  across accountIds: [UUID], in accounts: Accounts
) -> [Position] {
  var sums: [Instrument: Decimal] = [:]
  var order: [Instrument] = []
  for id in accountIds {
    guard let account = accounts.by(id: id) else { continue }
    for position in account.positions {
      if sums[position.instrument] == nil {
        order.append(position.instrument)
      }
      sums[position.instrument, default: 0] += position.quantity
    }
  }
  return order.compactMap { instrument in
    guard let quantity = sums[instrument] else { return nil }
    return Position(instrument: instrument, quantity: quantity)
  }
}
