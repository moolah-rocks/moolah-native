import SwiftUI

/// Inline-with-wrap layout for the row's per-instrument amount entries.
/// Lays out children horizontally with hairline spacing; wraps to a new
/// line when there isn't horizontal room. SwiftUI 6 / iOS 26 supports
/// `.layoutDirectionBehavior` and the `Layout` protocol — using a thin
/// custom `Layout` here keeps wrapping deterministic without nesting
/// `ViewThatFits`.
struct TransactionAmountFlow: View {
  let amounts: [InstrumentAmount]
  var colorOverride: Color?
  var positiveColorOverride: Color?
  var negativeColorOverride: Color?

  var body: some View {
    WrappedHStack(spacing: 6) {
      ForEach(amounts, id: \.self) { amount in
        InstrumentAmountView(
          amount: amount,
          font: .body,
          colorOverride: colorOverride(for: amount))
      }
    }
    .multilineTextAlignment(.trailing)
  }

  private func colorOverride(for amount: InstrumentAmount) -> Color? {
    if let colorOverride { return colorOverride }
    if amount.isPositive { return positiveColorOverride }
    if amount.isNegative { return negativeColorOverride }
    return nil
  }
}

/// Minimal trailing-aligned wrap layout. Lays each subview out on the
/// current line if it fits within the proposed width; otherwise wraps.
private struct WrappedHStack: Layout {
  var spacing: CGFloat = 6

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) -> CGSize {
    let maxWidth = proposal.width ?? .infinity
    var lineWidth: CGFloat = 0
    var totalWidth: CGFloat = 0
    var totalHeight: CGFloat = 0
    var lineHeight: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      let advance = (lineWidth == 0 ? 0 : spacing) + size.width
      if lineWidth + advance > maxWidth {
        totalWidth = max(totalWidth, lineWidth)
        totalHeight += lineHeight + spacing
        lineWidth = size.width
        lineHeight = size.height
      } else {
        lineWidth += advance
        lineHeight = max(lineHeight, size.height)
      }
    }
    totalWidth = max(totalWidth, lineWidth)
    totalHeight += lineHeight
    return CGSize(width: totalWidth, height: totalHeight)
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    // Right-aligned wrap. Build line-by-line, then place trailing-justified.
    var lines: [[(index: Int, size: CGSize)]] = [[]]
    var lineWidth: CGFloat = 0
    let maxWidth = bounds.width
    for (index, subview) in subviews.enumerated() {
      let size = subview.sizeThatFits(.unspecified)
      let advance = (lineWidth == 0 ? 0 : spacing) + size.width
      if lineWidth + advance > maxWidth, !lines[lines.count - 1].isEmpty {
        lines.append([])
        lineWidth = 0
      }
      lines[lines.count - 1].append((index, size))
      lineWidth += (lineWidth == 0 ? size.width : advance)
    }
    var y = bounds.minY
    for line in lines {
      let lineHeight = line.map(\.size.height).max() ?? 0
      let totalLineWidth =
        line.reduce(0) { $0 + $1.size.width }
        + CGFloat(max(line.count - 1, 0)) * spacing
      var x = bounds.maxX - totalLineWidth
      for (index, size) in line {
        subviews[index].place(
          at: CGPoint(x: x, y: y),
          proposal: ProposedViewSize(size))
        x += size.width + spacing
      }
      y += lineHeight + spacing
    }
  }
}
