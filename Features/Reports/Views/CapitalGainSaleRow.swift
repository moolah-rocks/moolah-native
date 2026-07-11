import SwiftUI

struct CapitalGainSaleRow: View {
  let sale: CapitalGainSale
  let profileInstrument: Instrument
  @State private var isExpanded = false

  private var gainAmount: InstrumentAmount {
    InstrumentAmount(quantity: sale.gain, instrument: profileInstrument)
  }

  private var quantityAmount: InstrumentAmount {
    InstrumentAmount(quantity: sale.quantity, instrument: sale.instrument)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      saleSummary
      saleDetails
      purchaseDisclosure
    }
    .padding(.vertical, 10)
  }

  private var saleSummary: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 2) {
        Text(sale.instrument.displayLabel)
          .font(.headline)
        Text(saleCaption)
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      Spacer()
      InstrumentAmountView(amount: gainAmount, font: .headline)
    }
  }

  private var saleCaption: String {
    let sold = "\(quantityAmount.formatted) sold \(TaxReportPresentation.dateLabel(sale.sellDate))"
    guard let ownerLabel = sale.ownerLabel else { return sold }
    return "\(ownerLabel) • \(sold)"
  }

  private var saleDetails: some View {
    HStack(spacing: 16) {
      detail("Proceeds", sale.proceeds)
      detail("Average cost", sale.volumeWeightedCost)
      detail("12-month gain", sale.discountEligibleGain)
    }
  }

  private var purchaseDisclosure: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(sale.lots) { lot in
          CapitalGainSaleLotRow(lot: lot, sale: sale, profileInstrument: profileInstrument)
        }
      }
      .padding(.top, 4)
    } label: {
      Text("\(sale.lots.count) purchase\(sale.lots.count == 1 ? "" : "s") used")
        .font(.caption)
    }
  }

  private func detail(_ label: String, _ quantity: Decimal, signed: Bool = false) -> some View {
    let amount = amount(quantity)
    return Text("\(label) \(signed ? amount.signedFormatted : amount.formatted)")
      .font(.caption)
      .foregroundStyle(.secondary)
      .monospacedDigit()
  }

  private func amount(_ quantity: Decimal) -> InstrumentAmount {
    InstrumentAmount(quantity: quantity, instrument: profileInstrument)
  }
}

private struct CapitalGainSaleLotRow: View {
  let lot: CapitalGainSaleLot
  let sale: CapitalGainSale
  let profileInstrument: Instrument

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(TaxReportPresentation.dateLabel(lot.acquiredDate))
        .font(.caption.weight(.semibold))
        .monospacedDigit()
      Text(detailText)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(TaxReportPresentation.holdingPeriodLabel(for: lot.event))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var detailText: String {
    let quantity = InstrumentAmount(quantity: lot.quantity, instrument: sale.instrument).formatted
    return
      "\(quantity) • Cost \(amount(lot.costBasis).formatted) • Proceeds \(amount(lot.proceeds).formatted) • Gain \(amount(lot.gain).signedFormatted)"
  }

  private func amount(_ quantity: Decimal) -> InstrumentAmount {
    InstrumentAmount(quantity: quantity, instrument: profileInstrument)
  }
}

#Preview("Capital Gain Sale Row") {
  CapitalGainSaleRow(
    sale: CapitalGainSaleRowPreviewData.sale,
    profileInstrument: .AUD
  )
  .padding()
  .frame(width: 390)
}

private enum CapitalGainSaleRowPreviewData {
  static let instrument = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP Group")

  static var sale: CapitalGainSale {
    TaxReportPresentation.saleRows(from: [
      CapitalGainEvent(
        sourceTransactionId: UUID(),
        instrument: instrument,
        sellDate: date(2026, 3, 1),
        acquiredDate: date(2024, 3, 1),
        quantity: 120,
        costBasis: 4_800,
        proceeds: 6_150,
        holdingDays: 730)
    ])[0]
  }

  static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    AustralianTaxCalendar.calendar.date(from: DateComponents(year: year, month: month, day: day))
      ?? Date()
  }
}
