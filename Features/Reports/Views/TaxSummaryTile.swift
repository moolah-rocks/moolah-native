import SwiftUI

struct TaxSummaryTile: View {
  let title: String
  let amount: InstrumentAmount
  let caption: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.subheadline)
        .foregroundStyle(.secondary)
      InstrumentAmountView(amount: amount, font: .title3)
      Text(caption)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title), \(amount.formatted), \(caption)")
  }
}
