import Foundation

extension HoldingsCostLedger {
  static func orderedEvents(_ events: [CostBasisEvent]) -> [CostBasisEvent] {
    let moveSourceKeys = Set(events.compactMap(moveSourceKey))
    let moveDestinationKeys = Set(events.compactMap(moveDestinationKey))
    return
      events.enumerated()
      .sorted { lhs, rhs in
        let lhsRank = eventOrderRank(
          lhs.element, moveSourceKeys: moveSourceKeys, moveDestinationKeys: moveDestinationKeys)
        let rhsRank = eventOrderRank(
          rhs.element, moveSourceKeys: moveSourceKeys, moveDestinationKeys: moveDestinationKeys)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return lhs.offset < rhs.offset
      }
      .map(\.element)
  }

  private static func eventOrderRank(
    _ event: CostBasisEvent,
    moveSourceKeys: Set<TouchKey>,
    moveDestinationKeys: Set<TouchKey>
  ) -> Int {
    switch event {
    case let .acquisition(instrument, _, _, holding):
      let key = TouchKey(
        account: holding.account,
        instrument: instrument,
        taxOwnerId: holding.taxOwnerId)
      return moveDestinationKeys.contains(key) ? 3 : 0
    case let .disposal(instrument, _, _, context):
      let key = TouchKey(
        account: context.holding.account,
        instrument: instrument,
        taxOwnerId: context.holding.taxOwnerId)
      return moveSourceKeys.contains(key) ? 1 : 4
    case .move:
      return 2
    }
  }

  private static func moveSourceKey(_ event: CostBasisEvent) -> TouchKey? {
    guard case let .move(instrument, _, route, _) = event else { return nil }
    return TouchKey(account: route.from, instrument: instrument, taxOwnerId: route.taxOwnerId)
  }

  private static func moveDestinationKey(_ event: CostBasisEvent) -> TouchKey? {
    guard case let .move(instrument, _, route, _) = event else { return nil }
    return TouchKey(account: route.to, instrument: instrument, taxOwnerId: route.taxOwnerId)
  }
}
