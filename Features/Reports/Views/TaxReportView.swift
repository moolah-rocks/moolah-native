// The tax report view co-locates owner selection, export state, and section routing to avoid widening view internals.
// swiftlint:disable file_length

import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct TaxReportView: View {
  let financialYear: Int
  let holdingsDate: Date
  let profileInstrument: Instrument
  let summary: CapitalGainsSummary?
  let events: [CapitalGainEvent]
  let capitalGainsHasUnavailableData: Bool
  let capitalGainsUnavailableInstruments: [Instrument]
  let capitalGainsHasUnavailableDataByOwner: [UUID: Bool]
  let ownerUnavailableCapitalGainsInstruments: [UUID: [Instrument]]
  let taxIncomeExpenseSummaries: [TaxIncomeExpenseSummary]
  let taxIncomeExpenseRollup: TaxIncomeExpenseSummary?
  let defaultTaxOwnerId: UUID
  let taxIncomeExpenseDateInterval: Range<Date>?
  let taxIncomeExpenseError: Error?
  let taxOwnerNames: [UUID: String]
  let taxOwnerKinds: [UUID: TaxOwnerKind]
  let profitLoss: [InstrumentProfitLoss]
  let profitLossHasUnavailableData: Bool
  let profitLossUnavailableInstruments: [Instrument]
  let profitLossByOwner: [UUID: [InstrumentProfitLoss]]
  let profitLossHasUnavailableDataByOwner: [UUID: Bool]
  let profitLossUnavailableInstrumentsByOwner: [UUID: [Instrument]]
  let isLoading: Bool
  let error: Error?
  let isMigratingCrossChainIdentity: Bool
  let reload: () -> Void

  @State private var salesSort: CapitalGainSaleSort = .sold(ascending: false)
  @State var exportDocument = TaxReportCSVDocument(csv: "")
  @State var isExportPresented = false
  @State var exportError: String?
  @State var selectedOwnerId: UUID?

  private var sortedSales: [CapitalGainSale] {
    salesSort.sorted(
      TaxReportPresentation.saleRows(
        from: selectedReport.events,
        taxOwnerNames: taxOwnerNames,
        defaultTaxOwnerId: defaultTaxOwnerId,
        includeOwnerLabels: selectedReport.effectiveOwnerId == nil && ownerSelection.isPickerVisible
      ))
  }

  private var financialYearEndHoldings: FinancialYearEndHoldingsPresentation {
    TaxReportPresentation.financialYearEndHoldings(
      from: selectedReport.profitLoss,
      profileInstrument: profileInstrument)
  }

  var reportInstruments: [Instrument] {
    selectedReport.events.map(\.instrument) + selectedReport.profitLoss.map(\.instrument)
  }

  private var financialYearEndLabel: String {
    TaxReportPresentation.dateLabel(holdingsDate)
  }

  var ownerSelection: TaxReportOwnerSelection {
    TaxReportOwnerSelection.options(for: taxOwnerNames, selectedOwnerId: selectedOwnerId)
  }
  var effectiveSelectedOwnerId: UUID? {
    ownerSelection.selectedOwnerId
  }
  var ownerPickerSelection: Binding<UUID?> {
    Binding(
      get: { ownerSelection.selectedOwnerId },
      set: { selectedOwnerId = $0 })
  }

  var selectedReport: TaxReportSelectionProjection {
    TaxReportSelectionProjection(
      ownerSelection: ownerSelection,
      events: events,
      allOwnerCapitalGainsSummary: summary,
      capitalGainsHasUnavailableData: capitalGainsHasUnavailableData,
      capitalGainsUnavailableInstruments: capitalGainsUnavailableInstruments,
      capitalGainsHasUnavailableDataByOwner: capitalGainsHasUnavailableDataByOwner,
      ownerUnavailableCapitalGainsInstruments: ownerUnavailableCapitalGainsInstruments,
      taxIncomeExpenseSummaries: taxIncomeExpenseSummaries,
      allOwnerTaxIncomeExpenseRollup: taxIncomeExpenseRollup,
      profitLoss: profitLoss,
      profitLossHasUnavailableData: profitLossHasUnavailableData,
      profitLossUnavailableInstruments: profitLossUnavailableInstruments,
      profitLossByOwner: profitLossByOwner,
      profitLossHasUnavailableDataByOwner: profitLossHasUnavailableDataByOwner,
      profitLossUnavailableInstrumentsByOwner: profitLossUnavailableInstrumentsByOwner,
      defaultTaxOwnerId: defaultTaxOwnerId,
      profileInstrument: profileInstrument,
      taxOwnerKinds: taxOwnerKinds)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        if isMigratingCrossChainIdentity {
          migrationUnavailable
        } else if let error {
          errorView(error)
        } else {
          reportToolbar
          ownerPicker
          reportSummaryTiles
          taxIncomeExpenseSection
          realisedCapitalGainsSection
          currentHoldingsSection
        }
      }
      .padding()
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .fileExporter(
      isPresented: $isExportPresented,
      document: exportDocument,
      contentType: .commaSeparatedText,
      defaultFilename: exportFilename
    ) { result in
      handleExportCompletion(result)
    }
    .alert("Could not export tax report", isPresented: exportErrorBinding) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(exportError ?? "Unknown export error")
    }
  }
}

extension TaxReportView {
  @ViewBuilder private var ownerPicker: some View {
    if ownerSelection.isPickerVisible {
      Picker("Tax owner", selection: ownerPickerSelection) {
        ForEach(ownerSelection.choices) { choice in
          Text(choice.label).tag(choice.id)
        }
      }
      .pickerStyle(.menu)
    }
  }

  @ViewBuilder private var realisedCapitalGainsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      if isLoading && selectedReport.capitalGainsSummary == nil {
        ProgressView("Loading tax report...")
          .frame(maxWidth: .infinity, minHeight: 180)
      } else if selectedReport.capitalGainsHasUnavailableData
        && selectedReport.capitalGainsSummary == nil
      {
        unavailableView(
          title: "Capital gains unavailable",
          description:
            "A price is missing for one or more sales, so Moolah cannot show a reliable capital gains total yet."
        )
      } else if selectedReport.capitalGainsSummary != nil {
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
    if let summary = selectedReport.capitalGainsSummary,
      !selectedReport.capitalGainsHasUnavailableData
    {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
        capitalGainsSummaryTiles(summary)
        holdingsSummaryTile
      }
    } else if selectedReport.capitalGainsSummary != nil {
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
    if selectedReport.ownerScopeUsesTrustTreatment {
      let values = summary.asTaxAdjustmentValues(currency: profileInstrument)
      TaxSummaryTile(
        title: "Short-term capital gains",
        amount: values.shortTerm,
        caption: "Before loss offsets")
      TaxSummaryTile(
        title: "Long-term capital gains",
        amount: values.longTerm,
        caption: "Before loss offsets or discounts")
      TaxSummaryTile(
        title: "Capital losses",
        amount: values.losses,
        caption: "Current-year losses")
    } else {
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
    }
    TaxSummaryTile(
      title: "Total sold gain/loss",
      amount: amount(summary.totalGain),
      caption: "\(summary.eventCount) sale\(summary.eventCount == 1 ? "" : "s")")
  }

  @ViewBuilder private var holdingsSummaryTile: some View {
    if selectedReport.profitLossHasUnavailableData {
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
      if selectedReport.capitalGainsUnavailableInstruments.isEmpty {
        ContentUnavailableView(
          "No sales",
          systemImage: "tray",
          description: Text("No investment sales found for this financial year."))
      } else {
        unavailableInstrumentRows(
          title: "Sales unavailable",
          instruments: selectedReport.capitalGainsUnavailableInstruments)
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
          instruments: selectedReport.capitalGainsUnavailableInstruments)
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
    if isLoading && selectedReport.profitLoss.isEmpty {
      ProgressView("Loading holdings...")
        .frame(maxWidth: .infinity, minHeight: 120)
    } else if selectedReport.profitLossHasUnavailableData && financialYearEndHoldings.rows.isEmpty {
      unavailableInstrumentRows(
        title: "Holdings unavailable",
        instruments: selectedReport.profitLossUnavailableInstruments)
    } else if financialYearEndHoldings.rows.isEmpty {
      ContentUnavailableView(
        "No holdings at \(financialYearEndLabel)",
        systemImage: "tray",
        description: Text("No tracked investment holdings found."))
    } else {
      financialYearEndHoldingsList(totalUnavailable: selectedReport.profitLossHasUnavailableData)
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
        instruments: selectedReport.profitLossUnavailableInstruments)
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
      title: "Tax report not ready yet",
      description:
        "Moolah is finishing an investment update. The tax report will appear here once that is done."
    )
  }

  private func errorView(_ error: Error) -> some View {
    ContentUnavailableView {
      Label("Could not load tax report", systemImage: "exclamationmark.triangle")
    } description: {
      Text(TaxReportPresentation.errorDescription(error, instruments: reportInstruments))
    } actions: {
      Button("Try again", action: reload)
    }
  }

  func sectionHeader(_ title: String) -> some View {
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
