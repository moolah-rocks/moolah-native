import Foundation
import SwiftUI

enum TaxIncomeExpenseDrillDownKind: Hashable {
  case income
  case deductions

  var transactionType: TransactionType {
    switch self {
    case .income:
      return .income
    case .deductions:
      return .expense
    }
  }

  var title: String {
    switch self {
    case .income:
      return "Taxable income"
    case .deductions:
      return "Deductions"
    }
  }
}

struct TaxIncomeExpenseDrillDown: Hashable {
  let kind: TaxIncomeExpenseDrillDownKind
  let ownerId: UUID?
  let ownerName: String?
  let dateInterval: Range<Date>
  let defaultTaxOwnerId: UUID

  var title: String {
    guard let ownerName else { return kind.title }
    return "\(ownerName) \(kind.title.lowercased())"
  }
}

@MainActor
@Observable
final class TaxIncomeExpenseDetailStore {
  private let categories: Categories
  private let taxOwnerNames: [UUID: String]
  private let loadRows: () async throws -> [TaxIncomeExpenseDetailRow]

  private(set) var rows: [TaxIncomeExpenseDetailRow] = []
  private(set) var isLoading = true
  private(set) var errorMessage: String?

  init(
    categories: Categories,
    taxOwnerNames: [UUID: String],
    loadRows: @escaping () async throws -> [TaxIncomeExpenseDetailRow]
  ) {
    self.categories = categories
    self.taxOwnerNames = taxOwnerNames
    self.loadRows = loadRows
  }

  func load() async {
    isLoading = true
    errorMessage = nil
    do {
      rows = try await loadRows()
    } catch {
      errorMessage = TaxReportPresentation.errorMessage(error)
      rows = []
    }
    isLoading = false
  }

  func categoryName(for row: TaxIncomeExpenseDetailRow) -> String {
    categories.by(id: row.categoryId).map { categories.path(for: $0) } ?? "Unknown category"
  }

  func detailCaption(for row: TaxIncomeExpenseDetailRow) -> String {
    let ownerName = taxOwnerNames[row.ownerId] ?? "Owner \(row.ownerId.uuidString.prefix(8))"
    return "\(ownerName) • \(row.instrument.displayLabel) • \(row.dayLabel)"
  }
}

struct TaxIncomeExpenseDetailView: View {
  let drillDown: TaxIncomeExpenseDrillDown
  @State private var store: TaxIncomeExpenseDetailStore

  init(
    drillDown: TaxIncomeExpenseDrillDown,
    categories: Categories,
    taxOwnerNames: [UUID: String],
    loadRows: @escaping () async throws -> [TaxIncomeExpenseDetailRow]
  ) {
    self.drillDown = drillDown
    self._store = State(
      initialValue: TaxIncomeExpenseDetailStore(
        categories: categories,
        taxOwnerNames: taxOwnerNames,
        loadRows: loadRows))
  }

  var body: some View {
    content
      .navigationTitle(drillDown.title)
      .task(id: drillDown) {
        await store.load()
      }
  }

  @ViewBuilder private var content: some View {
    if store.isLoading {
      ProgressView("Loading details...")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let errorMessage = store.errorMessage {
      ContentUnavailableView {
        Label("Could not load details", systemImage: "exclamationmark.triangle")
      } description: {
        Text(errorMessage)
      } actions: {
        Button("Try again") {
          Task { await store.load() }
        }
      }
    } else if store.rows.isEmpty {
      ContentUnavailableView("No matching tax rows", systemImage: "tray")
    } else {
      List(store.rows) { row in
        taxDetailRow(row)
      }
    }
  }

  private func taxDetailRow(_ row: TaxIncomeExpenseDetailRow) -> some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 3) {
        Text(store.categoryName(for: row))
          .font(.body.weight(.medium))
        Text(store.detailCaption(for: row))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 12)
      Text(amountText(for: row))
        .monospacedDigit()
        .foregroundStyle(row.hasUnavailableData ? .secondary : .primary)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(store.categoryName(for: row)), \(store.detailCaption(for: row))")
    .accessibilityValue(amountText(for: row))
  }

  private func amountText(for row: TaxIncomeExpenseDetailRow) -> String {
    guard !row.hasUnavailableData, let amount = row.amount else { return "Unavailable" }
    switch drillDown.kind {
    case .income:
      return amount.formatted
    case .deductions:
      return amount.formatted
    }
  }
}

#Preview("Tax income detail rows") {
  let preview = TaxIncomeExpenseDetailPreviewData()

  NavigationStack {
    TaxIncomeExpenseDetailView(
      drillDown: preview.drillDown,
      categories: preview.categories,
      taxOwnerNames: preview.taxOwnerNames
    ) {
      preview.rows
    }
  }
}

private struct TaxIncomeExpenseDetailPreviewData {
  private let primaryOwnerId = taxIncomeExpenseDetailPreviewUUID(
    "11111111-1111-1111-1111-111111111111")
  private let partnerOwnerId = taxIncomeExpenseDetailPreviewUUID(
    "22222222-2222-2222-2222-222222222222")
  private let incomeId = taxIncomeExpenseDetailPreviewUUID(
    "33333333-3333-3333-3333-333333333333")
  private let dividendsId = taxIncomeExpenseDetailPreviewUUID(
    "44444444-4444-4444-4444-444444444444")

  var categories: Categories {
    Categories(from: [
      Category(id: incomeId, name: "Income"),
      Category(id: dividendsId, name: "Dividends", parentId: incomeId, isTaxReportable: true),
    ])
  }

  var taxOwnerNames: [UUID: String] {
    [
      primaryOwnerId: "Alex",
      partnerOwnerId: "Sam",
    ]
  }

  var drillDown: TaxIncomeExpenseDrillDown {
    TaxIncomeExpenseDrillDown(
      kind: .income,
      ownerId: nil,
      ownerName: nil,
      dateInterval: Date()..<Date().addingTimeInterval(86_400),
      defaultTaxOwnerId: primaryOwnerId)
  }

  var rows: [TaxIncomeExpenseDetailRow] {
    [
      TaxIncomeExpenseDetailRow(
        ownerId: primaryOwnerId,
        categoryId: dividendsId,
        instrument: .AUD,
        day: nil,
        dayLabel: "5 Jan 2026",
        amount: InstrumentAmount(quantity: 126.50, instrument: .AUD)),
      TaxIncomeExpenseDetailRow(
        ownerId: partnerOwnerId,
        categoryId: dividendsId,
        instrument: .USD,
        day: nil,
        dayLabel: "Date unavailable",
        amount: nil,
        hasUnavailableData: true),
    ]
  }
}

private func taxIncomeExpenseDetailPreviewUUID(_ literal: String) -> UUID {
  guard let uuid = UUID(uuidString: literal) else {
    fatalError("Invalid tax income expense detail preview UUID")
  }
  return uuid
}
