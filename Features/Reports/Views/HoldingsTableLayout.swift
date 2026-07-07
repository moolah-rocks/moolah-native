import SwiftUI

#if os(macOS)
  enum HoldingsTableLayout {
    static let horizontalPadding: CGFloat = 12
    static let columnSpacing: CGFloat = 12

    static func instrument(_ layout: EndOfFinancialYearHoldingsTable.Layout) -> CGFloat {
      layout == .compact ? 190 : 220
    }

    static func quantity(_ layout: EndOfFinancialYearHoldingsTable.Layout) -> CGFloat {
      layout == .compact ? 104 : 130
    }

    static func money(_ layout: EndOfFinancialYearHoldingsTable.Layout) -> CGFloat {
      layout == .compact ? 120 : 135
    }

    static func totalWidth(_ layout: EndOfFinancialYearHoldingsTable.Layout) -> CGFloat {
      switch layout {
      case .regular:
        return horizontalPadding * 2 + instrument(layout) + quantity(layout) + money(layout) * 3
          + columnSpacing * 4
      case .compact:
        return horizontalPadding * 2 + instrument(layout) + quantity(layout) + money(layout) * 2
          + columnSpacing * 3
      }
    }
  }
#endif
