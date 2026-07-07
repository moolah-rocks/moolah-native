import SwiftUI

struct CurrentHoldingGainRow: View {
  let row: InstrumentProfitLoss
  let profileInstrument: Instrument

  private var unrealizedGain: InstrumentAmount {
    InstrumentAmount(quantity: row.unrealizedGain, instrument: profileInstrument)
  }

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(row.instrument.displayLabel)
          .font(.headline)
        Text(row.instrument.name)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      InstrumentAmountView(amount: unrealizedGain, font: .headline)
    }
    .padding(.vertical, 8)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "\(row.instrument.displayLabel), \(TaxReportPresentation.gainAccessibilityText(for: unrealizedGain))"
    )
  }
}

#Preview("Current Holding Gain Row") {
  CurrentHoldingGainRow(
    row: InstrumentProfitLoss(
      instrument: Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP Group Limited"),
      currentQuantity: 295,
      totalInvested: 30_528.59,
      currentValue: 30_569.16,
      realizedGain: 0,
      unrealizedGain: 40.57),
    profileInstrument: .AUD
  )
  .padding()
  .frame(width: 390)
}
