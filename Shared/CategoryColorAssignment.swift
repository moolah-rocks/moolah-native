import SwiftUI

/// Assigns a chart-series colour to each category in a breakdown so that a
/// chart's `chartForegroundStyleScale` and its accompanying legend resolve
/// **identical** colours for every category.
///
/// Colours are handed out by the category's position in the ordered
/// breakdown rather than by hashing its id. Position-based assignment gives
/// two guarantees the previous `abs(id.hashValue) % palette.count` approach
/// could not:
///
/// 1. **Stability** — a given breakdown always maps to the same colours, so
///    the result no longer changes between launches (Swift seeds `hashValue`
///    randomly per process).
/// 2. **Separability** — distinct categories take distinct palette entries
///    until the palette is exhausted, so neighbouring pie sectors / stacked
///    bands don't collide on the same colour the way independent hashes do.
///
/// Build one instance from the ordered breakdown and use it for *both* the
/// chart's colour scale and the legend swatches; that single source of truth
/// is what keeps the two in agreement.
struct CategoryColorAssignment {
  /// Ordered chart-series palette. Resolves through `Color+ChartPalette` so a
  /// future tuning pass stays in one file (see `UI_GUIDE` §5 exception).
  static let palette: [Color] = [
    .chartBlue, .chartGreen, .chartOrange, .chartPurple, .chartRed, .chartTeal,
    .chartIndigo, .chartPink, .chartMint, .chartCyan, .chartBrown, .chartYellow,
  ]

  private let colorsById: [UUID: Color]

  /// - Parameter orderedCategoryIds: the category ids in the order they appear
  ///   in the breakdown. A `nil` entry represents the uncategorized bucket and
  ///   is rendered grey without consuming a palette slot.
  init(orderedCategoryIds: [UUID?]) {
    var colors: [UUID: Color] = [:]
    var nextIndex = 0
    for case let id? in orderedCategoryIds where colors[id] == nil {
      colors[id] = Self.palette[nextIndex % Self.palette.count]
      nextIndex += 1
    }
    self.colorsById = colors
  }

  /// The colour for `id`. Uncategorized (`nil`) and any id outside the
  /// breakdown resolve to `.gray`.
  func color(for id: UUID?) -> Color {
    guard let id, let color = colorsById[id] else { return .gray }
    return color
  }
}
