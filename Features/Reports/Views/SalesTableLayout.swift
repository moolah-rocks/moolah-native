import SwiftUI

enum SalesTableLayout {
  static let horizontalPadding: CGFloat = 12
  static let columnSpacing: CGFloat = 7
  static let disclosure: CGFloat = 18
  static let dividerInset: CGFloat = 44
  static let detailLeadingPadding: CGFloat = 44

  static let lotColumnSpacing: CGFloat = 12
  static let lotDate: CGFloat = 94
  static let lotQuantity: CGFloat = 142
  static let lotMoney: CGFloat = 104
  static let lotHolding: CGFloat = 150
  static let lotWidth: CGFloat =
    lotDate + lotQuantity + lotMoney * 3 + lotHolding + lotColumnSpacing * 5

  static let regularWidth: CGFloat =
    horizontalPadding * 2 + disclosure + instrument(.regular) + date(.regular) + quantity(.regular)
    + money(.regular) * 3 + discountGain(.regular) + columnSpacing * 7

  static let compactWidth: CGFloat =
    horizontalPadding * 2 + disclosure + instrument(.compact) + date(.compact) + quantity(.compact)
    + money(.compact) * 3 + discountGain(.compact) + columnSpacing * 7

  static func instrument(_ layout: CapitalGainSalesTable.Layout) -> CGFloat {
    layout == .compact ? 64 : 130
  }

  static func date(_ layout: CapitalGainSalesTable.Layout) -> CGFloat {
    layout == .compact ? 74 : 96
  }

  static func quantity(_ layout: CapitalGainSalesTable.Layout) -> CGFloat {
    layout == .compact ? 86 : 150
  }

  static func money(_ layout: CapitalGainSalesTable.Layout) -> CGFloat {
    layout == .compact ? 76 : 116
  }

  static func discountGain(_ layout: CapitalGainSalesTable.Layout) -> CGFloat {
    layout == .compact ? 86 : 116
  }
}
