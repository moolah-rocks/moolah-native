import Foundation
import SwiftUI

#Preview("Tax owner transaction drill-down") {
  let preview = TaxIncomeExpenseDetailPreviewData()
  return NavigationStack {
    TaxIncomeExpenseDetailView(
      drillDown: preview.drillDown,
      profileInstrument: .AUD,
      accounts: preview.accounts,
      categories: preview.categories,
      earmarks: Earmarks(from: []),
      transactionStore: preview.transactionStore
    ) {
      preview.rows
    }
  }
  .previewProfileEnvironment()
  .task {
    do {
      try await preview.seed()
      await preview.transactionStore.observeTaxRelevantChanges(filter: preview.transactionFilter)
    } catch {
      assertionFailure("Could not seed tax transaction drill-down preview: \(error)")
    }
  }
}

@MainActor
private struct TaxIncomeExpenseDetailPreviewData {
  private let backend: any BackendProvider
  let transactionStore: TransactionStore

  private let ownerId = previewUUID("11111111-1111-1111-1111-111111111111")
  private let accountId = previewUUID("22222222-2222-2222-2222-222222222222")
  private let categoryId = previewUUID("33333333-3333-3333-3333-333333333333")
  private let newerTransactionId = previewUUID("44444444-4444-4444-4444-444444444444")
  private let olderTransactionId = previewUUID("55555555-5555-5555-5555-555555555555")

  init() {
    let backend = PreviewBackend.create()
    self.backend = backend
    self.transactionStore = TransactionStore(
      repository: backend.transactions,
      conversionService: backend.conversionService,
      targetInstrument: .AUD)
  }

  var account: Account {
    Account(
      id: accountId,
      name: "Investments",
      type: .investment,
      instrument: .AUD,
      taxOwnerIds: [ownerId])
  }

  var category: Category {
    Category(
      id: categoryId,
      name: "Dividends",
      isTaxReportable: true)
  }

  var accounts: Accounts { Accounts(from: [account]) }
  var categories: Categories { Categories(from: [category]) }

  var drillDown: TaxIncomeExpenseDrillDown {
    TaxIncomeExpenseDrillDown(
      kind: .income,
      ownerId: ownerId,
      ownerName: "Alex",
      dateInterval: Date().addingTimeInterval(-172_800)..<Date().addingTimeInterval(86_400),
      defaultTaxOwnerId: ownerId)
  }

  var transactionFilter: TransactionFilter {
    TransactionFilter(
      scheduled: .nonScheduledOnly,
      dateInterval: drillDown.dateInterval,
      taxReportableLegType: drillDown.kind.transactionType,
      taxOwnerId: drillDown.ownerId,
      taxDefaultOwnerId: drillDown.defaultTaxOwnerId)
  }

  var rows: [TaxIncomeExpenseDetailRow] {
    [
      row(transactionId: newerTransactionId, amount: 63.25),
      row(transactionId: olderTransactionId, amount: 31.625),
    ]
  }

  func seed() async throws {
    _ = try await backend.accounts.create(account)
    _ = try await backend.categories.create(category)
    _ = try await backend.transactions.create(
      transaction(id: newerTransactionId, payee: "Betashares", amount: 126.50, daysAgo: 1))
    _ = try await backend.transactions.create(
      transaction(id: olderTransactionId, payee: "Vanguard", amount: 63.25, daysAgo: 2))
  }

  private func row(transactionId: UUID, amount: Decimal) -> TaxIncomeExpenseDetailRow {
    TaxIncomeExpenseDetailRow(
      transactionId: transactionId,
      ownerId: ownerId,
      categoryId: categoryId,
      instrument: .AUD,
      day: Date(),
      amount: InstrumentAmount(quantity: amount, instrument: .AUD),
      isSplitAcrossTaxOwners: true)
  }

  private func transaction(
    id: UUID,
    payee: String,
    amount: Decimal,
    daysAgo: TimeInterval
  ) -> Transaction {
    Transaction(
      id: id,
      date: Date().addingTimeInterval(-daysAgo * 86_400),
      payee: payee,
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: .AUD,
          quantity: amount,
          type: .income,
          categoryId: categoryId)
      ])
  }
}

private func previewUUID(_ literal: String) -> UUID {
  guard let uuid = UUID(uuidString: literal) else {
    fatalError("Invalid tax income expense detail preview UUID")
  }
  return uuid
}
