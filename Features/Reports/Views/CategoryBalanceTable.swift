import SwiftUI

/// Displays a table of category balances grouped by root category with expandable subcategories.
/// Used for both income and expense columns in the Reports view.
struct CategoryBalanceTable: View {
  let title: String
  let balances: [UUID: InstrumentAmount]
  let categories: Categories
  let dateRange: ClosedRange<Date>
  let profileInstrument: Instrument
  /// Total of legs with no category, `nil` when there are none in range —
  /// the row is omitted entirely rather than shown as zero.
  let uncategorised: InstrumentAmount?
  /// Type this table represents (income or expense), used to scope the
  /// "Uncategorised" row's drill-down.
  let transactionType: TransactionType
  /// Mirrors `ReportingStore`'s `income`/`expenseHasUnavailableData` — true
  /// when a transient conversion failure means some rows were skipped, so
  /// the total may be understated.
  let hasUnavailableData: Bool

  private var reportData: [CategoryGroup] {
    // Group subcategories under roots
    var roots: [UUID: CategoryGroup] = [:]

    for (categoryId, amount) in balances {
      guard categories.by(id: categoryId) != nil else { continue }

      // Find root category
      let rootId = rootCategoryId(for: categoryId)

      // Get or create root group
      var group =
        roots[rootId]
        ?? CategoryGroup(
          categoryId: rootId,
          name: categories.by(id: rootId).map { categories.path(for: $0) } ?? "Unknown",
          totalAmount: .zero(instrument: amount.instrument),
          children: []
        )

      // If this is the root itself, just add to total
      if categoryId == rootId {
        group.totalAmount += amount
      } else {
        // Add as child
        group.children.append(
          CategoryChild(
            categoryId: categoryId,
            name: categories.by(id: categoryId).map { categories.path(for: $0) } ?? "Unknown",
            amount: amount
          ))
        group.totalAmount += amount
      }

      roots[rootId] = group
    }

    // Sort roots by total (descending), then children by amount (descending)
    return roots.values
      .map { group in
        var sorted = group
        sorted.children.sort { $0.amount.quantity.magnitude > $1.amount.quantity.magnitude }
        return sorted
      }
      .sorted { $0.totalAmount.quantity.magnitude > $1.totalAmount.quantity.magnitude }
  }

  /// Seed the reduce with a zero in the profile instrument so empty balances
  /// render as the right currency. All `balances` entries come from the
  /// repository's `fetchCategoryBalancesByType` which returns values in the
  /// profile instrument, so instrument parity with the seed holds. Includes
  /// `uncategorised` when present so the Total reconciles with the sum of
  /// visible rows.
  private var grandTotal: InstrumentAmount {
    let categorisedTotal = balances.values.reduce(.zero(instrument: profileInstrument), +)
    guard let uncategorised else { return categorisedTotal }
    return categorisedTotal + uncategorised
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if reportData.isEmpty && uncategorised == nil {
        ContentUnavailableView(
          "No Transactions",
          systemImage: "tray",
          description: Text("No transactions found for this period"))
      } else {
        categoryList
      }
      Divider()
      footer
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(title).font(.title2).fontWeight(.semibold)
        Spacer()
      }
      if hasUnavailableData {
        incompleteDataCaption
      }
    }
    .padding()
  }

  private var incompleteDataCaption: some View {
    Text("Some prices are still loading; totals may be incomplete")
      .font(.caption)
      .foregroundStyle(.secondary)
  }

  private var footer: some View {
    HStack {
      Text("Total").font(.headline)
      Spacer()
      InstrumentAmountView(amount: grandTotal, font: .headline)
    }
    .padding()
  }

  private var categoryList: some View {
    List {
      ForEach(reportData) { group in
        categorySection(group)
      }
      if let uncategorised {
        uncategorisedSection(uncategorised)
      }
    }
    #if os(macOS)
      .listStyle(.inset)
    #else
      .listStyle(.plain)
    #endif
  }

  /// Pinned after all category sections (bottom of the list) so it reads as
  /// a peer of the category rows without competing with them for sort order.
  private func uncategorisedSection(_ amount: InstrumentAmount) -> some View {
    Section {
      NavigationLink(
        value: UncategorisedDrillDown(transactionType: transactionType, dateRange: dateRange)
      ) {
        HStack {
          Text("Uncategorised").font(.headline)
          Spacer()
          InstrumentAmountView(amount: amount, font: .headline)
        }
      }
      .accessibilityLabel("Uncategorised, \(amount.formatted)")
    }
  }

  private func categorySection(_ group: CategoryGroup) -> some View {
    Section {
      if !group.children.isEmpty {
        ForEach(group.children) { child in
          NavigationLink(
            value: CategoryDrillDown(categoryId: child.categoryId, dateRange: dateRange)
          ) {
            HStack {
              Text(child.name).font(.body)
              Spacer()
              InstrumentAmountView(amount: child.amount)
            }
          }
          .accessibilityLabel("\(child.name), \(child.amount.formatted)")
        }
      }
    } header: {
      HStack {
        Text(group.name).font(.headline)
        Spacer()
        InstrumentAmountView(amount: group.totalAmount, font: .headline)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("\(group.name), \(group.totalAmount.formatted)")
    }
  }

  private func rootCategoryId(for categoryId: UUID) -> UUID {
    var current = categoryId
    while let category = categories.by(id: current),
      let parentId = category.parentId
    {
      current = parentId
    }
    return current
  }

}

struct CategoryGroup: Identifiable {
  let categoryId: UUID
  let name: String
  var totalAmount: InstrumentAmount
  var children: [CategoryChild]

  var id: UUID { categoryId }
}

struct CategoryChild: Identifiable {
  let categoryId: UUID
  let name: String
  let amount: InstrumentAmount

  var id: UUID { categoryId }
}

struct CategoryDrillDown: Hashable {
  let categoryId: UUID
  let dateRange: ClosedRange<Date>
}

/// Drill-down target for the Reports "Uncategorised" row — type-scoped
/// (income or expense) rather than category-scoped.
struct UncategorisedDrillDown: Hashable {
  let transactionType: TransactionType
  let dateRange: ClosedRange<Date>
}

#Preview {
  let salaryId = UUID()
  let bonusId = UUID()
  let contractingId = UUID()
  let incomeId = UUID()
  let interestId = UUID()
  let categories = Categories(from: [
    Category(id: incomeId, name: "Income"),
    Category(id: salaryId, name: "Salary", parentId: incomeId),
    Category(id: bonusId, name: "Bonus", parentId: incomeId),
    Category(id: contractingId, name: "Contracting", parentId: incomeId),
    Category(id: interestId, name: "Interest"),
  ])
  let balances: [UUID: InstrumentAmount] = [
    salaryId: InstrumentAmount(quantity: 4200, instrument: .AUD),
    bonusId: InstrumentAmount(quantity: 1500, instrument: .AUD),
    contractingId: InstrumentAmount(quantity: 800, instrument: .AUD),
    interestId: InstrumentAmount(quantity: 120, instrument: .AUD),
  ]
  let start = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
  CategoryBalanceTable(
    title: "Income",
    balances: balances,
    categories: categories,
    dateRange: start...Date(),
    profileInstrument: .AUD,
    uncategorised: InstrumentAmount(quantity: 250, instrument: .AUD),
    transactionType: .income,
    hasUnavailableData: false
  )
  .frame(width: 500, height: 400)
}

#Preview("Unavailable data") {
  let salaryId = UUID()
  let incomeId = UUID()
  let categories = Categories(from: [
    Category(id: incomeId, name: "Income"),
    Category(id: salaryId, name: "Salary", parentId: incomeId),
  ])
  let balances: [UUID: InstrumentAmount] = [
    salaryId: InstrumentAmount(quantity: 4200, instrument: .AUD)
  ]
  let start = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
  CategoryBalanceTable(
    title: "Income",
    balances: balances,
    categories: categories,
    dateRange: start...Date(),
    profileInstrument: .AUD,
    uncategorised: InstrumentAmount(quantity: 250, instrument: .AUD),
    transactionType: .income,
    hasUnavailableData: true
  )
  .frame(width: 500, height: 400)
}
