import Foundation
import SwiftUI

extension TaxReportView {
  var reportToolbar: some View {
    HStack {
      VStack(alignment: .leading, spacing: 4) {
        Text("Tax report")
          .font(.title3.weight(.semibold))
        Text(TaxReportPresentation.financialYearLabel(financialYear))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button {
        exportDocument = TaxReportCSVDocument(csv: TaxReportExportBuilder.csv(for: exportInput))
        isExportPresented = true
      } label: {
        Label("Export CSV", systemImage: "square.and.arrow.up")
      }
      .disabled(!canExport)
      .accessibilityHint("Exports this tax report as a CSV file.")
    }
  }

  var exportFilename: String {
    "moolah-tax-report-\(financialYear - 1)-\(String(format: "%02d", financialYear % 100)).csv"
  }

  var exportErrorBinding: Binding<Bool> {
    Binding(
      get: { exportError != nil },
      set: { isPresented in
        if !isPresented { exportError = nil }
      })
  }

  func handleExportCompletion(_ result: Result<URL, Error>) {
    exportError = Self.exportFailureMessage(for: result)
  }

  nonisolated static func exportFailureMessage(for result: Result<URL, Error>) -> String? {
    if case let .failure(error) = result {
      return error.localizedDescription
    }
    return nil
  }

  private var canExport: Bool {
    !isLoading && !isMigratingCrossChainIdentity && error == nil && taxIncomeExpenseError == nil
  }

  private var exportInput: TaxReportExportInput {
    TaxReportExportInput(
      financialYear: financialYear,
      holdingsDate: holdingsDate,
      profileInstrument: profileInstrument,
      selectedOwnerId: effectiveSelectedOwnerId,
      summary: selectedReport.capitalGainsSummary,
      events: selectedReport.events,
      capitalGainsHasUnavailableData: selectedReport.capitalGainsHasUnavailableData,
      capitalGainsUnavailableInstruments: selectedReport.capitalGainsUnavailableInstruments,
      capitalGainsHasUnavailableDataByOwner: capitalGainsHasUnavailableDataByOwner,
      ownerUnavailableCapitalGainsInstruments: ownerUnavailableCapitalGainsInstruments,
      taxIncomeExpenseSummaries: selectedReport.taxIncomeExpenseSummaries,
      taxIncomeExpenseRollup: selectedReport.taxIncomeExpenseRollup,
      taxOwnerNames: taxOwnerNames,
      taxOwnerKinds: taxOwnerKinds,
      profitLoss: selectedReport.profitLoss,
      profitLossHasUnavailableData: selectedReport.profitLossHasUnavailableData,
      profitLossUnavailableInstruments: selectedReport.profitLossUnavailableInstruments,
      defaultTaxOwnerId: defaultTaxOwnerId)
  }
}
