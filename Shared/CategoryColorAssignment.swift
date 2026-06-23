import SwiftUI

/// Assigns a chart-series colour to each category in a breakdown so that a
/// chart's `chartForegroundStyleScale` and its accompanying legend resolve
/// **identical** colours for every category.
///
/// Colours are handed out by the category's position in the ordered
/// breakdown — which both charts sort largest-first — rather than by hashing
/// its id. This gives three properties the previous
/// `abs(id.hashValue) % palette.count` approach could not:
///
/// 1. **Stability** — a given breakdown always maps to the same colours, so
///    the result no longer changes between launches (Swift seeds `hashValue`
///    randomly per process).
/// 2. **Separability** — distinct categories take distinct palette entries, so
///    neighbouring pie sectors / stacked bands don't collide on the same
///    colour the way independent hashes did.
/// 3. **Honest overflow** — the palette holds as many genuinely distinct,
///    dark-mode-tuned hues as remain reliably distinguishable (≈11; see
///    ColorBrewer / D3 categorical scales). Categories past it — always the
///    smallest, barely-visible slices because the breakdown is sorted
///    descending — resolve to `.gray` rather than to a muddy generated colour
///    or a wrapped duplicate. They still appear individually in the legend.
///
/// Build one instance from the ordered breakdown and use it for *both* the
/// chart's colour scale and the legend swatches; that single source of truth
/// is what keeps the two in agreement.
struct CategoryColorAssignment {
  /// Curated chart-series palette, ordered so the largest categories (assigned
  /// first) stay maximally separated in hue. Resolves through
  /// `Color+ChartPalette` so a future tuning pass stays in one file (see
  /// `UI_GUIDE` §5 exception). Deliberately omits `.chartCyan`, which is
  /// near-indistinguishable from `.chartTeal`.
  static let palette: [Color] = [
    .chartBlue, .chartOrange, .chartGreen, .chartRed, .chartPurple, .chartYellow,
    .chartTeal, .chartPink, .chartIndigo, .chartBrown, .chartMint,
  ]

  private let colorsById: [UUID: Color]

  /// - Parameter orderedCategoryIds: the category ids in the order they appear
  ///   in the breakdown (largest first). A `nil` entry represents the
  ///   uncategorized bucket and resolves to `.gray` without consuming a
  ///   palette slot.
  init(orderedCategoryIds: [UUID?]) {
    var colors: [UUID: Color] = [:]
    var nextIndex = 0
    for case let id? in orderedCategoryIds where colors[id] == nil {
      colors[id] = nextIndex < Self.palette.count ? Self.palette[nextIndex] : .gray
      nextIndex += 1
    }
    self.colorsById = colors
  }

  /// The colour for `id`. Uncategorized (`nil`), categories past the palette,
  /// and any id outside the breakdown all resolve to `.gray`.
  func color(for id: UUID?) -> Color {
    guard let id, let color = colorsById[id] else { return .gray }
    return color
  }
}
