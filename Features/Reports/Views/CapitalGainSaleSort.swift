import Foundation

enum CapitalGainSaleSort: Equatable {
  case instrument(ascending: Bool)
  case sold(ascending: Bool)
  case quantity(ascending: Bool)
  case volumeWeightedCost(ascending: Bool)
  case proceeds(ascending: Bool)
  case gain(ascending: Bool)
  case discountEligibleGain(ascending: Bool)

  var toggled: CapitalGainSaleSort {
    switch self {
    case .instrument(let ascending): return .instrument(ascending: !ascending)
    case .sold(let ascending): return .sold(ascending: !ascending)
    case .quantity(let ascending): return .quantity(ascending: !ascending)
    case .volumeWeightedCost(let ascending): return .volumeWeightedCost(ascending: !ascending)
    case .proceeds(let ascending): return .proceeds(ascending: !ascending)
    case .gain(let ascending): return .gain(ascending: !ascending)
    case .discountEligibleGain(let ascending): return .discountEligibleGain(ascending: !ascending)
    }
  }

  func sorted(_ rows: [CapitalGainSale]) -> [CapitalGainSale] {
    rows.sorted { lhs, rhs in
      let primary = primaryComparison(lhs, rhs)
      if primary != .same { return primary == .orderedBefore }
      return CapitalGainSale.stableAscendingOrder(lhs, rhs)
    }
  }

  private func primaryComparison(_ lhs: CapitalGainSale, _ rhs: CapitalGainSale) -> SortComparison {
    switch self {
    case .instrument(let ascending):
      return compare(lhs.instrument.displayLabel, rhs.instrument.displayLabel, ascending)
    case .sold(let ascending):
      return compare(lhs.sellDate, rhs.sellDate, ascending)
    case .quantity(let ascending):
      return compare(lhs.quantity, rhs.quantity, ascending)
    case .volumeWeightedCost(let ascending):
      return compare(lhs.volumeWeightedCost, rhs.volumeWeightedCost, ascending)
    case .proceeds(let ascending):
      return compare(lhs.proceeds, rhs.proceeds, ascending)
    case .gain(let ascending):
      return compare(lhs.gain, rhs.gain, ascending)
    case .discountEligibleGain(let ascending):
      return compare(lhs.discountEligibleGain, rhs.discountEligibleGain, ascending)
    }
  }

  private func compare<T: Comparable>(_ lhs: T, _ rhs: T, _ ascending: Bool) -> SortComparison {
    if lhs == rhs { return .same }
    return ascending == (lhs < rhs) ? .orderedBefore : .orderedAfter
  }

  func isCurrent(_ column: CapitalGainSaleSort.Column) -> Bool {
    switch (self, column) {
    case (.instrument, .instrument),
      (.sold, .sold),
      (.quantity, .quantity),
      (.volumeWeightedCost, .volumeWeightedCost),
      (.proceeds, .proceeds),
      (.gain, .gain),
      (.discountEligibleGain, .discountEligibleGain):
      return true
    default:
      return false
    }
  }

  var isAscending: Bool {
    switch self {
    case .instrument(let ascending),
      .sold(let ascending),
      .quantity(let ascending),
      .volumeWeightedCost(let ascending),
      .proceeds(let ascending),
      .gain(let ascending),
      .discountEligibleGain(let ascending):
      return ascending
    }
  }
}

private enum SortComparison {
  case orderedBefore
  case orderedAfter
  case same
}

extension CapitalGainSaleSort {
  enum Column {
    case instrument
    case sold
    case quantity
    case volumeWeightedCost
    case proceeds
    case gain
    case discountEligibleGain

    var defaultSort: CapitalGainSaleSort {
      switch self {
      case .instrument: return .instrument(ascending: true)
      case .sold: return .sold(ascending: false)
      case .quantity: return .quantity(ascending: false)
      case .volumeWeightedCost: return .volumeWeightedCost(ascending: false)
      case .proceeds: return .proceeds(ascending: false)
      case .gain: return .gain(ascending: false)
      case .discountEligibleGain: return .discountEligibleGain(ascending: false)
      }
    }
  }
}
