import SwiftUI

extension TaxReportView {
  var sortedTaxIncomeExpenseSummaries: [TaxIncomeExpenseSummary] {
    taxIncomeExpenseSummaries.sorted {
      let lhsName = taxOwnerName(for: $0.ownerId)
      let rhsName = taxOwnerName(for: $1.ownerId)
      if lhsName != rhsName {
        return lhsName.localizedStandardCompare(rhsName) == .orderedAscending
      }
      return $0.ownerId.uuidString < $1.ownerId.uuidString
    }
  }

  var taxIncomeExpenseSection: some View {
    Group {
      if let taxIncomeExpenseError {
        taxIncomeExpenseErrorView(taxIncomeExpenseError)
      } else if let summary = taxIncomeExpenseRollup {
        VStack(alignment: .leading, spacing: 12) {
          sectionHeader("Taxable income and deductions")
          taxIncomeExpenseRollupView(summary)
          taxOwnerIncomeExpenseRows
        }
      }
    }
  }

  private func taxIncomeExpenseRollupView(
    _ summary: TaxIncomeExpenseSummary
  ) -> some View {
    Group {
      Text("All owners")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
      if summary.hasUnavailableData {
        ContentUnavailableView {
          Label("Taxable income total unavailable", systemImage: "exclamationmark.triangle")
        } description: {
          Text(
            "One or more owner totals are missing a price, so Moolah cannot show a reliable all-owner total yet."
          )
        }
      } else {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
          TaxSummaryTile(
            title: "Taxable income",
            amount: summary.taxableIncome,
            caption: "Reportable income categories")
          TaxSummaryTile(
            title: "Deductions",
            amount: summary.deductibleExpenses,
            caption: "Reportable expense categories")
          TaxSummaryTile(
            title: "Net taxable income",
            amount: summary.netTaxableIncome,
            caption: "Income less deductions")
        }
      }
    }
  }

  @ViewBuilder private var taxOwnerIncomeExpenseRows: some View {
    if sortedTaxIncomeExpenseSummaries.count > 1 {
      VStack(alignment: .leading, spacing: 8) {
        Text("By owner")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.secondary)
        ViewThatFits(in: .horizontal) {
          taxOwnerIncomeExpenseGrid
          taxOwnerIncomeExpenseCompactRows
        }
      }
    }
  }

  private var taxOwnerIncomeExpenseGrid: some View {
    Grid(alignment: .trailingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 8) {
      GridRow {
        Text("Owner")
          .gridColumnAlignment(.leading)
        Text("Income")
        Text("Deductions")
        Text("Net")
      }
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)

      ForEach(sortedTaxIncomeExpenseSummaries) { summary in
        GridRow {
          Text(taxOwnerName(for: summary.ownerId))
            .font(.body.weight(.medium))
            .lineLimit(1)
            .truncationMode(.middle)
          taxOwnerAmount(summary.taxableIncome, unavailable: summary.hasUnavailableData)
          taxOwnerAmount(summary.deductibleExpenses, unavailable: summary.hasUnavailableData)
          taxOwnerAmount(summary.netTaxableIncome, unavailable: summary.hasUnavailableData)
        }
        .accessibilityElement(children: .combine)
      }
    }
  }

  private var taxOwnerIncomeExpenseCompactRows: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(sortedTaxIncomeExpenseSummaries) { summary in
        VStack(alignment: .leading, spacing: 4) {
          Text(taxOwnerName(for: summary.ownerId))
            .font(.body.weight(.medium))
          taxOwnerCompactAmount("Income", summary.taxableIncome, summary.hasUnavailableData)
          taxOwnerCompactAmount(
            "Deductions", summary.deductibleExpenses, summary.hasUnavailableData)
          taxOwnerCompactAmount("Net", summary.netTaxableIncome, summary.hasUnavailableData)
        }
        .accessibilityElement(children: .combine)
      }
    }
  }

  private func taxOwnerAmount(
    _ amount: InstrumentAmount,
    unavailable: Bool
  ) -> some View {
    Text(unavailable ? "Unavailable" : amount.formatted)
      .monospacedDigit()
      .foregroundStyle(unavailable ? .secondary : .primary)
  }

  private func taxOwnerCompactAmount(
    _ label: String,
    _ amount: InstrumentAmount,
    _ unavailable: Bool
  ) -> some View {
    HStack {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer(minLength: 12)
      taxOwnerAmount(amount, unavailable: unavailable)
    }
  }

  private func taxIncomeExpenseErrorView(_ error: Error) -> some View {
    ContentUnavailableView {
      Label("Could not load taxable income", systemImage: "exclamationmark.triangle")
    } description: {
      Text(TaxReportPresentation.errorDescription(error, instruments: reportInstruments))
    } actions: {
      Button("Try again", action: reload)
    }
  }

  private func taxOwnerName(for ownerId: UUID) -> String {
    taxOwnerNames[ownerId] ?? "Owner \(ownerId.uuidString.prefix(8))"
  }
}
