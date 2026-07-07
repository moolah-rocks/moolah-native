import Foundation

#if os(macOS)
  enum HoldingsSort {
    case instrument(ascending: Bool)
    case quantity(ascending: Bool)
    case cost(ascending: Bool)
    case value(ascending: Bool)
    case gain(ascending: Bool)

    enum Column {
      case instrument
      case quantity
      case cost
      case value
      case gain

      var defaultSort: HoldingsSort {
        switch self {
        case .instrument: return .instrument(ascending: true)
        case .quantity: return .quantity(ascending: false)
        case .cost: return .cost(ascending: false)
        case .value: return .value(ascending: false)
        case .gain: return .gain(ascending: false)
        }
      }
    }

    var toggled: HoldingsSort {
      switch self {
      case .instrument(let ascending): return .instrument(ascending: !ascending)
      case .quantity(let ascending): return .quantity(ascending: !ascending)
      case .cost(let ascending): return .cost(ascending: !ascending)
      case .value(let ascending): return .value(ascending: !ascending)
      case .gain(let ascending): return .gain(ascending: !ascending)
      }
    }

    var isAscending: Bool {
      switch self {
      case .instrument(let ascending),
        .quantity(let ascending),
        .cost(let ascending),
        .value(let ascending),
        .gain(let ascending):
        return ascending
      }
    }

    func isCurrent(_ column: Column) -> Bool {
      switch (self, column) {
      case (.instrument, .instrument), (.quantity, .quantity), (.cost, .cost), (.value, .value),
        (.gain, .gain):
        return true
      default:
        return false
      }
    }

    func sorted(_ rows: [InstrumentProfitLoss]) -> [InstrumentProfitLoss] {
      rows.sorted { lhs, rhs in
        switch self {
        case .instrument(let ascending):
          return order(
            lhs,
            rhs,
            compare(lhs.instrument.displayLabel, rhs.instrument.displayLabel, ascending))
        case .quantity(let ascending):
          return order(lhs, rhs, compare(lhs.currentQuantity, rhs.currentQuantity, ascending))
        case .cost(let ascending):
          return order(
            lhs, rhs, compare(remainingCostBasis(lhs), remainingCostBasis(rhs), ascending))
        case .value(let ascending):
          return order(lhs, rhs, compare(lhs.currentValue, rhs.currentValue, ascending))
        case .gain(let ascending):
          return order(lhs, rhs, compare(lhs.unrealizedGain, rhs.unrealizedGain, ascending))
        }
      }
    }

    private func compare<T: Comparable>(
      _ lhs: T,
      _ rhs: T,
      _ ascending: Bool
    ) -> HoldingsSortComparison {
      if lhs == rhs { return .same }
      return ascending == (lhs < rhs) ? .orderedBefore : .orderedAfter
    }

    private func stableAscendingOrder(
      _ lhs: InstrumentProfitLoss,
      _ rhs: InstrumentProfitLoss
    ) -> Bool {
      if lhs.instrument.displayLabel != rhs.instrument.displayLabel {
        return lhs.instrument.displayLabel < rhs.instrument.displayLabel
      }
      return lhs.instrument.id < rhs.instrument.id
    }

    private func order(
      _ lhs: InstrumentProfitLoss,
      _ rhs: InstrumentProfitLoss,
      _ comparison: HoldingsSortComparison
    ) -> Bool {
      comparison == .same ? stableAscendingOrder(lhs, rhs) : comparison == .orderedBefore
    }

    private func remainingCostBasis(_ row: InstrumentProfitLoss) -> Decimal {
      row.currentValue - row.unrealizedGain
    }
  }

  private enum HoldingsSortComparison {
    case orderedBefore
    case orderedAfter
    case same
  }
#endif
