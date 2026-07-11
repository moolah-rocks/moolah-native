import SwiftUI

struct TaxSummaryTile: View {
  let title: String
  let amount: InstrumentAmount
  let caption: String
  var unavailable = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.subheadline)
        .foregroundStyle(.secondary)
      amountView
      Text(caption)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title), \(accessibilityAmount), \(caption)")
  }

  @ViewBuilder private var amountView: some View {
    if unavailable {
      Text("Unavailable")
        .font(.title3)
        .monospacedDigit()
        .foregroundStyle(.secondary)
    } else {
      InstrumentAmountView(amount: amount, font: .title3)
    }
  }

  private var accessibilityAmount: String {
    unavailable ? "Unavailable" : amount.formatted
  }
}

#Preview("Tax summary tile states") {
  VStack(alignment: .leading, spacing: 12) {
    TaxSummaryTile(
      title: "Taxable income",
      amount: InstrumentAmount(quantity: 8_420.75, instrument: .AUD),
      caption: "Open to inspect income rows")
    TaxSummaryTile(
      title: "Deductions",
      amount: .zero(instrument: .AUD),
      caption: "Open to inspect unavailable deduction rows",
      unavailable: true)
  }
  .padding()
}
