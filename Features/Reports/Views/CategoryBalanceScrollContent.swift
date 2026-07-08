import SwiftUI

struct CategoryBalanceScrollContent: View {
  let reportData: [CategoryGroup]
  let uncategorised: InstrumentAmount?
  let transactionType: TransactionType
  let dateRange: ClosedRange<Date>
  let headerVerticalPadding: CGFloat

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
        InstrumentAmountView(amount: amount, font: .headline)
        disclosureIndicator
      }
      .padding(.horizontal)
      .padding(.vertical, 12)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Uncategorised, \(amount.formatted)")
  }

  private func rootRow(_ group: CategoryGroup) -> some View {
    NavigationLink(
      value: CategoryDrillDown(
        categoryId: group.categoryId, dateRange: dateRange, includeDescendants: true)
    ) {
      HStack {
        Text(group.name).font(.headline)
        Spacer()
        InstrumentAmountView(amount: group.totalAmount, font: .headline)
        disclosureIndicator
      }
      .padding(.horizontal)
      .padding(.vertical, headerVerticalPadding)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(group.name), \(group.totalAmount.formatted)")
    .accessibilityIdentifier(UITestIdentifiers.Reports.categoryHeader(group.categoryId))
  }

  private func childRow(_ child: CategoryChild) -> some View {
    NavigationLink(
      value: CategoryDrillDown(categoryId: child.categoryId, dateRange: dateRange)
    ) {
      HStack {
        Text(child.name).font(.body)
        Spacer()
        InstrumentAmountView(amount: child.amount)
        disclosureIndicator
      }
      .padding(.horizontal)
      .padding(.vertical, 12)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(child.name), \(child.amount.formatted)")
  }

  private var disclosureIndicator: some View {
    Image(systemName: "chevron.forward")
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .accessibilityHidden(true)
  }
}
