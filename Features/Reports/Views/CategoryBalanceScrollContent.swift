import SwiftUI

struct CategoryBalanceScrollContent: View {
  let reportData: [CategoryGroup]
  let uncategorised: InstrumentAmount?
  let transactionType: TransactionType
  let dateRange: ClosedRange<Date>
  let headerVerticalPadding: CGFloat
  let hasUnavailableData: Bool

  var body: some View {
    LazyVStack(spacing: 0) {
      ForEach(reportData.indices, id: \.self) { index in
        categorySection(reportData[index])
        if shouldShowDivider(afterGroupAt: index) {
          Divider()
        }
      }
      if let uncategorised {
        uncategorisedRow(uncategorised)
      }
    }
  }

  private func categorySection(_ group: CategoryGroup) -> some View {
    VStack(spacing: 0) {
      rootRow(group)
      ForEach(group.children) { child in
        Divider()
        childRow(child)
      }
    }
  }

  private func shouldShowDivider(afterGroupAt index: Int) -> Bool {
    index < reportData.index(before: reportData.endIndex) || uncategorised != nil
  }

  private func uncategorisedRow(_ amount: InstrumentAmount) -> some View {
    NavigationLink(
      value: UncategorisedDrillDown(transactionType: transactionType, dateRange: dateRange)
    ) {
      HStack {
        Text("Uncategorised").font(.headline)
        Spacer()
        amountView(amount, font: .headline)
        disclosureIndicator
      }
      .padding(.horizontal)
      .padding(.vertical, 12)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Uncategorised, \(amountAccessibilityLabel(amount))")
  }

  private func rootRow(_ group: CategoryGroup) -> some View {
    NavigationLink(
      value: CategoryDrillDown(
        categoryId: group.categoryId, dateRange: dateRange, includeDescendants: true)
    ) {
      HStack {
        Text(group.name).font(.headline)
        Spacer()
        amountView(group.totalAmount, font: .headline)
        disclosureIndicator
      }
      .padding(.horizontal)
      .padding(.vertical, headerVerticalPadding)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(group.name), \(amountAccessibilityLabel(group.totalAmount))")
    .accessibilityIdentifier(UITestIdentifiers.Reports.categoryHeader(group.categoryId))
  }

  private func childRow(_ child: CategoryChild) -> some View {
    NavigationLink(
      value: CategoryDrillDown(categoryId: child.categoryId, dateRange: dateRange)
    ) {
      HStack {
        Text(child.name).font(.body)
        Spacer()
        amountView(child.amount)
        disclosureIndicator
      }
      .padding(.horizontal)
      .padding(.vertical, 12)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(child.name), \(amountAccessibilityLabel(child.amount))")
  }

  private var disclosureIndicator: some View {
    Image(systemName: "chevron.forward")
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .accessibilityHidden(true)
  }

  @ViewBuilder
  private func amountView(_ amount: InstrumentAmount, font: Font? = nil) -> some View {
    if let displayed = CategoryBalanceAvailabilityPresentation.displayedAmount(
      amount, hasUnavailableData: hasUnavailableData)
    {
      InstrumentAmountView(amount: displayed, font: font)
    } else {
      Text("—").font(font)
    }
  }

  private func amountAccessibilityLabel(_ amount: InstrumentAmount) -> String {
    hasUnavailableData ? "amount unavailable" : amount.formatted
  }
}
