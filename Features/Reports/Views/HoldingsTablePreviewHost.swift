import SwiftUI

#if os(macOS)
  private struct HoldingsTablePreviewHost: View {
    var body: some View {
      ScrollView(.horizontal) {
        EndOfFinancialYearHoldingsTable(
          rows: TaxReportPreviewData.holdings,
          profileInstrument: .AUD
        )
        .padding()
      }
      .frame(width: 960, height: 260)
    }
  }

  #Preview("Holdings at Date Table") {
    HoldingsTablePreviewHost()
  }
#endif
