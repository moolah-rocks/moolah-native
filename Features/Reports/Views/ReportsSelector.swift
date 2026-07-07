import SwiftUI

struct ReportsSelector: View {
  @Binding var selectedReport: ReportSection
  @Binding var dateRange: DateRange
  @Binding var customFrom: Date
  @Binding var customTo: Date
  @Binding var selectedFinancialYear: Int

  var body: some View {
    #if os(iOS)
      VStack(alignment: .leading, spacing: 12) {
        reportPicker
        selectedReportControls
      }
      .padding()
    #else
      HStack(spacing: 16) {
        reportPicker
        selectedReportControls
        Spacer()
      }
      .padding()
    #endif
  }

  private var reportPicker: some View {
    Picker("Report", selection: $selectedReport) {
      ForEach(ReportSection.allCases) { report in
        Text(report.rawValue).tag(report)
      }
    }
    .pickerStyle(.segmented)
  }

  @ViewBuilder private var selectedReportControls: some View {
    if selectedReport == .incomeAndExpenses {
      incomeAndExpenseControls
    } else {
      capitalGainsControls
    }
  }

  @ViewBuilder private var incomeAndExpenseControls: some View {
    Picker("Date Range", selection: $dateRange) {
      ForEach(DateRange.allCases) { range in
        Text(range.displayName).tag(range)
      }
    }
    .pickerStyle(.menu)
    #if os(macOS)
      .frame(width: 200)
    #endif

    if dateRange == .custom {
      DatePicker("From", selection: $customFrom, displayedComponents: .date)
        .labelsHidden()
      DatePicker("To", selection: $customTo, displayedComponents: .date)
        .labelsHidden()
    }
  }

  private var capitalGainsControls: some View {
    Picker("Financial Year", selection: $selectedFinancialYear) {
      ForEach(TaxReportPresentation.financialYears(), id: \.self) { year in
        Text(TaxReportPresentation.financialYearLabel(year)).tag(year)
      }
    }
    .pickerStyle(.menu)
    #if os(macOS)
      .fixedSize(horizontal: true, vertical: false)
    #endif
  }
}

#Preview("Reports Selector - Capital Gains") {
  @Previewable @State var selectedReport = ReportSection.capitalGains
  @Previewable @State var dateRange = DateRange.thisFinancialYear
  @Previewable @State var customFrom = Date()
  @Previewable @State var customTo = Date()
  @Previewable @State var selectedFinancialYear = 2026

  ReportsSelector(
    selectedReport: $selectedReport,
    dateRange: $dateRange,
    customFrom: $customFrom,
    customTo: $customTo,
    selectedFinancialYear: $selectedFinancialYear
  )
  .frame(width: 760)
}
