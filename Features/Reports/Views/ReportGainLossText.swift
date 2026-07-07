import SwiftUI

struct ReportGainLossText: View {
  let amount: InstrumentAmount

  var body: some View {
    Text(amount.signedFormatted)
      .monospacedDigit()
      .foregroundStyle(color)
      .accessibilityLabel(TaxReportPresentation.gainAccessibilityText(for: amount))
  }

  private var color: Color {
    if amount.quantity > 0 { return .green }
    if amount.quantity < 0 { return .red }
    return .primary
  }
}
