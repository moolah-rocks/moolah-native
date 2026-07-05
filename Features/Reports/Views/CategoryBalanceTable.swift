import SwiftUI

/// Displays a table of category balances grouped by root category with expandable subcategories.
/// Used for both income and expense columns in the Reports view.
struct CategoryBalanceTable: View {
  let title: String
  let balances: [UUID: InstrumentAmount]
  let categories: Categories
  let dateRange: ClosedRange<Date>
  let profileInstrument: Instrument

  // Tappable-header vertical padding. Touch platforms need a taller target
  // (44pt HIG minimum) than the pointer-driven Mac; both scale with Dynamic
  // Type. Mirrors `TransactionRowView`'s row-padding convention.
  #if os(macOS)
    @ScaledMetric private var headerVerticalPadding: CGFloat = 8
  #else
    @ScaledMetric private var headerVerticalPadding: CGFloat = 12
  #endif

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
  /// profile instrument, so instrument parity with the seed holds.
  private var grandTotal: InstrumentAmount {
    balances.values.reduce(.zero(instrument: profileInstrument), +)
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if reportData.isEmpty {
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
    HStack {
      Text(title).font(.title2).fontWeight(.semibold)
      Spacer()
    }
    .padding()
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
    }
    #if os(macOS)
      .listStyle(.inset)
    #else
      .listStyle(.plain)
    #endif
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
      NavigationLink(
        value: CategoryDrillDown(
          categoryId: group.categoryId, dateRange: dateRange, includeDescendants: true)
      ) {
        HStack {
          Text(group.name).font(.headline)
          Spacer()
          InstrumentAmountView(amount: group.totalAmount, font: .headline)
          // Explicit disclosure cue: a bold `List` section header otherwise
          // reads as a static group title, giving no hint that the whole
          // header now drills into the category's transactions.
          Image(systemName: "chevron.forward")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
        // Guarantee a comfortable tap target: section headers render more
        // compact than data rows, but this one is now a navigation control.
        .padding(.vertical, headerVerticalPadding)
        .contentShape(Rectangle())
      }
      .accessibilityLabel("\(group.name), \(group.totalAmount.formatted)")
      .accessibilityIdentifier(UITestIdentifiers.Reports.categoryHeader(group.categoryId))
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
  /// When set, the drill-down covers `categoryId` plus every descendant
  /// (used by tappable root headers); otherwise only the exact category.
  var includeDescendants = false

  /// The category ids the drill-down's transaction list filters on. A root
  /// header (`includeDescendants`) covers the whole subtree so its list
  /// matches the aggregated header total; a subcategory row matches only its
  /// own directly-categorised transactions.
  func categoryIds(in categories: Categories) -> Set<UUID> {
    includeDescendants ? categories.subtreeIds(of: categoryId) : [categoryId]
  }
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
    profileInstrument: .AUD
  )
  .frame(width: 500, height: 400)
}
