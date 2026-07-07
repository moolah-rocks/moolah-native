import SwiftUI

private struct CapitalGainSalesTablePreviewHost: View {
  @State private var sort: CapitalGainSaleSort = .sold(ascending: false)

  private let sales = CapitalGainSalesTablePreviewData.sales

  var body: some View {
    ScrollView(.horizontal) {
      ScrollView {
        CapitalGainSalesTable(
          sales: sort.sorted(sales),
          profileInstrument: .AUD,
          sort: $sort,
          initiallyExpanded: [CapitalGainSalesTablePreviewData.expandedSaleId]
        )
        .padding()
        .frame(width: 1180)
      }
    }
    .frame(width: 1180, height: 520)
  }
}

private enum CapitalGainSalesTablePreviewData {
  static let optimism = Instrument.crypto(
    chainId: 10,
    contractAddress: "0x4200000000000000000000000000000000000042",
    symbol: "OP",
    name: "Optimism",
    decimals: 18)
  static let eth = Instrument.crypto(
    chainId: 1,
    contractAddress: nil,
    symbol: "ETH",
    name: "Ethereum",
    decimals: 18)
  static let expandedSaleId = CapitalGainSaleIdentifier.transaction(
    uuid("11111111-1111-1111-1111-111111111111"),
    instrumentId: optimism.id)

  static var sales: [CapitalGainSale] {
    TaxReportPresentation.saleRows(from: [
      event(
        sourceTransactionId: uuid("11111111-1111-1111-1111-111111111111"),
        instrument: optimism,
        sellDate: date(2026, 3, 1),
        acquiredDate: date(2025, 11, 30),
        value: PreviewSaleValue(quantity: 20_167, costBasis: 9871.08, proceeds: 3497.35)),
      event(
        sourceTransactionId: uuid("22222222-2222-2222-2222-222222222222"),
        instrument: optimism,
        sellDate: date(2026, 3, 1),
        acquiredDate: date(2025, 10, 31),
        value: PreviewSaleValue(quantity: 0.93897033, costBasis: 0.58, proceeds: 0.16)),
      event(
        sourceTransactionId: uuid("22222222-2222-2222-2222-222222222222"),
        instrument: optimism,
        sellDate: date(2026, 3, 1),
        acquiredDate: date(2025, 11, 30),
        value: PreviewSaleValue(quantity: 196.53333333, costBasis: 96.20, proceeds: 34.03)),
      event(
        sourceTransactionId: uuid("22222222-2222-2222-2222-222222222222"),
        instrument: optimism,
        sellDate: date(2026, 3, 1),
        acquiredDate: date(2025, 11, 30),
        value: PreviewSaleValue(quantity: 14_624.74999976, costBasis: 7158.33, proceeds: 2532.16)),
      event(
        sourceTransactionId: uuid("33333333-3333-3333-3333-333333333333"),
        instrument: eth,
        sellDate: date(2025, 10, 1),
        acquiredDate: date(2024, 4, 15),
        value: PreviewSaleValue(quantity: 0.003, costBasis: 20.46, proceeds: 19.74)),
      event(
        sourceTransactionId: uuid("44444444-4444-4444-4444-444444444444"),
        instrument: Instrument.stock(ticker: "IOZ.AX", exchange: "ASX", name: "IOZ"),
        sellDate: date(2025, 8, 20),
        acquiredDate: date(2023, 8, 15),
        value: PreviewSaleValue(quantity: 17_726, costBasis: 596_675.72, proceeds: 637_062.94)),
    ])
  }

  private static func event(
    sourceTransactionId: UUID,
    instrument: Instrument,
    sellDate: Date,
    acquiredDate: Date,
    value: PreviewSaleValue
  ) -> CapitalGainEvent {
    CapitalGainEvent(
      sourceTransactionId: sourceTransactionId,
      instrument: instrument,
      sellDate: sellDate,
      acquiredDate: acquiredDate,
      quantity: value.quantity,
      costBasis: value.costBasis,
      proceeds: value.proceeds,
      holdingDays: Calendar.utc.dateComponents([.day], from: acquiredDate, to: sellDate).day ?? 0
    )
  }

  private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    guard let date = Calendar.utc.date(from: DateComponents(year: year, month: month, day: day))
    else {
      fatalError("Could not construct preview date")
    }
    return date
  }

  private static func uuid(_ value: String) -> UUID {
    guard let uuid = UUID(uuidString: value) else {
      fatalError("Could not construct preview UUID")
    }
    return uuid
  }
}

private struct PreviewSaleValue {
  let quantity: Decimal
  let costBasis: Decimal
  let proceeds: Decimal
}

#Preview("Capital Gain Sales Table") {
  CapitalGainSalesTablePreviewHost()
}
