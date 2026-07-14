import SwiftUI

struct TaxIncomeExpenseDetailView: View {
  let drillDown: TaxIncomeExpenseDrillDown
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let transactionStore: TransactionStore

  @State private var store: TaxIncomeExpenseDetailStore
  @State private var selectedTransaction: Transaction?

  init(
    drillDown: TaxIncomeExpenseDrillDown,
    profileInstrument: Instrument,
    accounts: Accounts,
    categories: Categories,
    earmarks: Earmarks,
    transactionStore: TransactionStore,
    loadRows: @escaping () async throws -> [TaxIncomeExpenseDetailRow]
  ) {
    self.drillDown = drillDown
    self.accounts = accounts
    self.categories = categories
    self.earmarks = earmarks
    self.transactionStore = transactionStore
    self._store = State(
      initialValue: TaxIncomeExpenseDetailStore(
        profileInstrument: profileInstrument,
        showsOwnerShareIndicators: drillDown.ownerId != nil,
        loadRows: loadRows))
  }

  var body: some View {
    transactionList
      .safeAreaInset(edge: .top) { unavailableDataBanner }
      .accessibilityHidden(isBlocking)
      .allowsHitTesting(!isBlocking)
      .overlay { statusOverlay }
      .transactionInspector(
        selectedTransaction: $selectedTransaction,
        accounts: accounts,
        categories: categories,
        earmarks: earmarks,
        transactionStore: transactionStore
      )
      .task(id: taxDetailLoadKey) {
        guard transactionStore.taxRelevantContentGeneration > 0,
          store.hasLoadedRows || hasPublishedInitialTransactionPage
        else { return }
        await store.load()
      }
  }
}

extension TaxIncomeExpenseDetailView {
  private var transactionList: some View {
    TransactionListView(
      title: drillDown.title,
      filter: taxTransactionFilter,
      accounts: accounts,
      categories: categories,
      earmarks: earmarks,
      transactionStore: transactionStore,
      amountPresentation: store.presentation(
        for: transactionStore.unfilteredTransactions,
        style: drillDown.kind.amountStyle),
      allowsScheduledFilter: false,
      allowsAddingTransactions: false,
      allowsSpamFiltering: false,
      emptyState: TransactionListEmptyState(
        title: "No Matching Tax Transactions",
        systemImage: "doc.text.magnifyingglass",
        description: "No transactions contribute to this tax total."),
      selectedTransaction: $selectedTransaction)
  }

  private var taxTransactionFilter: TransactionFilter {
    TransactionFilter(
      scheduled: .nonScheduledOnly,
      dateInterval: drillDown.dateInterval,
      taxReportableLegType: drillDown.kind.transactionType,
      taxOwnerId: drillDown.ownerId,
      taxDefaultOwnerId: drillDown.defaultTaxOwnerId)
  }

  private var hasPublishedInitialTransactionPage: Bool {
    transactionStore.currentFilter == taxTransactionFilter
      && transactionStore.lastSnapshotPage != nil
  }

  private var taxDetailLoadKey: TaxDetailLoadKey {
    TaxDetailLoadKey(
      hasPublishedInitialTransactionPage: hasPublishedInitialTransactionPage,
      taxRelevantContentGeneration: transactionStore.taxRelevantContentGeneration)
  }

  private var isBlocking: Bool {
    shouldShowTaxStatus && (store.isLoading || store.errorMessage != nil)
  }

  private var shouldShowTaxStatus: Bool {
    store.hasLoadedRows || hasPublishedInitialTransactionPage
  }

  @ViewBuilder private var unavailableDataBanner: some View {
    if let refreshErrorMessage = store.refreshErrorMessage {
      HStack(spacing: 12) {
        Label(refreshErrorMessage, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.secondary)
        Spacer()
        Button("Try again") {
          Task { await store.load() }
        }
      }
      .padding(.horizontal)
      .padding(.vertical, 8)
      .background(.bar)
    } else if store.hasUnavailableData, !store.isLoading, store.errorMessage == nil {
      HStack(spacing: 12) {
        Label(
          "Some tax amounts couldn’t be converted because rates or prices are unavailable.",
          systemImage: "exclamationmark.triangle"
        )
        .foregroundStyle(.secondary)
        Spacer()
        Button("Try again") {
          Task { await store.load() }
        }
      }
      .padding(.horizontal)
      .padding(.vertical, 8)
      .background(.bar)
    }
  }

  @ViewBuilder private var statusOverlay: some View {
    if shouldShowTaxStatus, store.isLoading {
      ProgressView("Loading transactions...")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    } else if shouldShowTaxStatus, let errorMessage = store.errorMessage {
      ContentUnavailableView {
        Label("Could not load tax amounts", systemImage: "exclamationmark.triangle")
      } description: {
        Text(errorMessage)
      } actions: {
        Button("Try again") {
          Task { await store.load() }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(.regularMaterial)
    }
  }

  private struct TaxDetailLoadKey: Hashable {
    let hasPublishedInitialTransactionPage: Bool
    let taxRelevantContentGeneration: UInt64
  }
}
