import SwiftUI

struct TaxReportView: View {
  let financialYear: Int
  let holdingsDate: Date
  let profileInstrument: Instrument
  let summary: CapitalGainsSummary?
  let events: [CapitalGainEvent]
  let capitalGainsHasUnavailableData: Bool
  let capitalGainsUnavailableInstruments: [Instrument]
  let profitLoss: [InstrumentProfitLoss]
  let profitLossHasUnavailableData: Bool
  let profitLossUnavailableInstruments: [Instrument]
  let isLoading: Bool
  let error: Error?
  let isMigratingCrossChainIdentity: Bool
  let reload: () -> Void

  @State private var salesSort: CapitalGainSaleSort = .sold(ascending: false)

  private var sortedSales: [CapitalGainSale] {
    salesSort.sorted(TaxReportPresentation.saleRows(from: events))
  }

  private var financialYearEndHoldings: FinancialYearEndHoldingsPresentation {
    TaxReportPresentation.financialYearEndHoldings(
      from: profitLoss,
      profileInstrument: profileInstrument)
  }

  private var reportInstruments: [Instrument] {
    events.map(\.instrument) + profitLoss.map(\.instrument)
  }

  private var financialYearEndLabel: String {
    TaxReportPresentation.dateLabel(holdingsDate)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        if isMigratingCrossChainIdentity {
          migrationUnavailable
        } else if let error {
          errorView(error)
        } else {
          reportSummaryTiles
          realisedCapitalGainsSection
          currentHoldingsSection
        }
      }
      .padding()
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
  }
}

extension TaxReportView {
  @ViewBuilder private var realisedCapitalGainsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      if isLoading && summary == nil {
        ProgressView("Loading capital gains...")
          .frame(maxWidth: .infinity, minHeight: 180)
      } else if capitalGainsHasUnavailableData && summary == nil {
        unavailableView(
          title: "Capital gains unavailable",
          description:
            "A price is missing for one or more sales, so Moolah cannot show a reliable capital gains total yet."
        )
      } else if summary != nil {
        disposalList
      } else {
        ContentUnavailableView(
          "No capital gains",
          systemImage: "chart.line.downtrend.xyaxis",
          description: Text("No sales found for this financial year."))
      }
    }
  }

  @ViewBuilder private var reportSummaryTiles: some View {
    if let summary, !capitalGainsHasUnavailableData {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
        capitalGainsSummaryTiles(summary)
        holdingsSummaryTile
      }
    } else if summary != nil {
      VStack(alignment: .leading, spacing: 12) {
        unavailableView(
          title: "Capital gains total unavailable",
          description:
            "A price is missing for one or more sales, so Moolah cannot show a reliable capital gains total yet."
        )
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
          holdingsSummaryTile
        }
      }
    } else if !financialYearEndHoldings.rows.isEmpty {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
        holdingsSummaryTile
      }
    }
  }

  @ViewBuilder
  private func capitalGainsSummaryTiles(_ summary: CapitalGainsSummary) -> some View {
    TaxSummaryTile(
      title: "Net capital gain",
      amount: amount(summary.netCapitalGain),
      caption: "After the 12-month discount")
    TaxSummaryTile(
      title: "Short-term",
      amount: amount(summary.shortTermGain),
      caption: "Held 12 months or less")
    TaxSummaryTile(
      title: "Long-term",
      amount: amount(summary.longTermGain),
      caption: "Before any discount")
    TaxSummaryTile(
      title: "Total sold gain/loss",
      amount: amount(summary.totalGain),
      caption: "\(summary.eventCount) sale\(summary.eventCount == 1 ? "" : "s")")
  }

  @ViewBuilder private var holdingsSummaryTile: some View {
    if profitLossHasUnavailableData {
      EmptyView()
    } else if !financialYearEndHoldings.rows.isEmpty {
      TaxSummaryTile(
        title: "Gain/loss while held",
        amount: financialYearEndHoldings.unrealizedTotal,
        caption: "Only becomes a capital gain or loss when you sell")
    }
  }

  @ViewBuilder private var disposalList: some View {
    if sortedSales.isEmpty {
      if capitalGainsUnavailableInstruments.isEmpty {
        ContentUnavailableView(
          "No sales",
          systemImage: "tray",
          description: Text("No investment sales found for this financial year."))
      } else {
        unavailableInstrumentRows(
          title: "Sales unavailable",
          instruments: capitalGainsUnavailableInstruments)
      }
    } else {
      VStack(alignment: .leading, spacing: 8) {
        Text("Sales")
          .font(.headline)
        Text("Investments marked as spam are excluded.")
          .font(.caption)
          .foregroundStyle(.secondary)
        #if os(macOS)
          macSalesTable
        #else
          ForEach(sortedSales) { sale in
            CapitalGainSaleRow(sale: sale, profileInstrument: profileInstrument)
          }
        #endif
        unavailableInstrumentRows(
          title: "Sales unavailable",
          instruments: capitalGainsUnavailableInstruments)
      }
    }
  }

  @ViewBuilder private var currentHoldingsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      financialYearEndHoldingsHeader
      financialYearEndHoldingsContent
    }
  }

  private var financialYearEndHoldingsHeader: some View {
    VStack(alignment: .leading, spacing: 2) {
      sectionHeader("Holdings at \(financialYearEndLabel)")
      Text("Investments marked as spam are excluded.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder private var financialYearEndHoldingsContent: some View {
    if isLoading && profitLoss.isEmpty {
      ProgressView("Loading holdings...")
        .frame(maxWidth: .infinity, minHeight: 120)
    } else if profitLossHasUnavailableData && financialYearEndHoldings.rows.isEmpty {
      unavailableInstrumentRows(
        title: "Holdings unavailable",
        instruments: profitLossUnavailableInstruments)
    } else if financialYearEndHoldings.rows.isEmpty {
      ContentUnavailableView(
        "No holdings at \(financialYearEndLabel)",
        systemImage: "tray",
        description: Text("No tracked investment holdings found."))
    } else {
      financialYearEndHoldingsList(totalUnavailable: profitLossHasUnavailableData)
    }
  }

  private func financialYearEndHoldingsList(totalUnavailable: Bool) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if totalUnavailable {
        unavailableView(
          title: "Holdings total unavailable",
          description:
            "A price is missing for one or more holdings, so Moolah cannot show a reliable total gain or loss at \(financialYearEndLabel) yet."
        )
      }
      #if os(macOS)
        macHoldingsTable
      #else
        ForEach(financialYearEndHoldings.rows) { row in
          CurrentHoldingGainRow(row: row, profileInstrument: profileInstrument)
        }
      #endif
      unavailableInstrumentRows(
        title: "Holdings unavailable",
        instruments: profitLossUnavailableInstruments)
    }
  }

  @ViewBuilder
  private func unavailableInstrumentRows(
    title: String,
    instruments: [Instrument]
  ) -> some View {
    if !instruments.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Text(title)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        ForEach(instruments, id: \.id) { instrument in
          HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
              .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
              Text(instrument.displayLabel)
              if instrument.name != instrument.displayLabel {
                Text(instrument.name)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            Spacer()
            Text("Unavailable")
              .foregroundStyle(.secondary)
          }
          .padding(.vertical, 6)
          .accessibilityElement(children: .combine)
        }
      }
    }
  }

  #if os(macOS)
    private var macSalesTable: some View {
      ViewThatFits(in: .horizontal) {
        regularSalesTable
        compactSalesTable
        ScrollView(.horizontal) {
          compactSalesTable
            .frame(width: SalesTableLayout.compactWidth, alignment: .leading)
        }
      }
    }

    private var regularSalesTable: some View {
      CapitalGainSalesTable(
        sales: sortedSales,
        profileInstrument: profileInstrument,
        layout: .regular,
        sort: $salesSort
      )
      .frame(minWidth: SalesTableLayout.regularWidth, maxWidth: .infinity, alignment: .leading)
    }

    private var compactSalesTable: some View {
      CapitalGainSalesTable(
        sales: sortedSales,
        profileInstrument: profileInstrument,
        layout: .compact,
        sort: $salesSort
      )
      .frame(minWidth: SalesTableLayout.compactWidth, maxWidth: .infinity, alignment: .leading)
    }

    private var macHoldingsTable: some View {
      ViewThatFits(in: .horizontal) {
        regularHoldingsTable
        compactHoldingsTable
        ScrollView(.horizontal) {
          compactHoldingsTable
            .frame(width: HoldingsTableLayout.totalWidth(.compact), alignment: .leading)
        }
      }
    }

    private var regularHoldingsTable: some View {
      EndOfFinancialYearHoldingsTable(
        rows: financialYearEndHoldings.rows,
        profileInstrument: profileInstrument,
        layout: .regular
      )
      .frame(
        minWidth: HoldingsTableLayout.totalWidth(.regular), maxWidth: .infinity, alignment: .leading
      )
    }

    private var compactHoldingsTable: some View {
      EndOfFinancialYearHoldingsTable(
        rows: financialYearEndHoldings.rows,
        profileInstrument: profileInstrument,
        layout: .compact
      )
      .frame(
        minWidth: HoldingsTableLayout.totalWidth(.compact), maxWidth: .infinity, alignment: .leading
      )
    }
  #endif

  private var migrationUnavailable: some View {
    unavailableView(
      title: "Capital gains report not ready yet",
      description:
        "Moolah is finishing an investment update. Capital gains will appear here once that is done."
    )
  }

  private func errorView(_ error: Error) -> some View {
    ContentUnavailableView {
      Label("Could not load capital gains", systemImage: "exclamationmark.triangle")
    } description: {
      Text(TaxReportPresentation.errorDescription(error, instruments: reportInstruments))
    } actions: {
      Button("Try again", action: reload)
    }
  }

  private func sectionHeader(_ title: String) -> some View {
    Text(title)
      .font(.headline)
  }

  private func unavailableView(title: String, description: String) -> some View {
    ContentUnavailableView {
      Label(title, systemImage: "exclamationmark.triangle")
    } description: {
      Text(description)
    } actions: {
      Button("Try again", action: reload)
    }
  }

  private func amount(_ quantity: Decimal) -> InstrumentAmount {
    InstrumentAmount(quantity: quantity, instrument: profileInstrument)
  }
}
