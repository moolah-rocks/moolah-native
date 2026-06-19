import SwiftUI

struct EarmarkDetailView: View {
  let earmark: Earmark
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let transactionStore: TransactionStore
  let analysisRepository: AnalysisRepository
  @State private var showEditSheet = false
  @State private var selectedTransaction: Transaction?
  @Environment(EarmarkStore.self) private var earmarkStore
  @Environment(ProfileSession.self) private var session

  var body: some View {
    EarmarkOverviewWithTabs {
      overviewPanel
    } transactions: {
      TransactionListView(
        title: earmark.name,
        filter: TransactionFilter(earmarkId: earmark.id),
        accounts: accounts,
        categories: categories,
        earmarks: earmarks,
        transactionStore: transactionStore,
        selectedTransaction: $selectedTransaction
      )
    } budget: {
      EarmarkBudgetSectionView(
        earmark: earmark,
        categories: categories,
        analysisRepository: analysisRepository
      )
    }
    .transactionInspector(
      selectedTransaction: $selectedTransaction,
      accounts: accounts,
      categories: categories,
      earmarks: earmarks,
      transactionStore: transactionStore
    )
    .profileNavigationTitle(earmark.name)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          showEditSheet = true
        } label: {
          Label("Edit", systemImage: "pencil")
        }
      }
    }
    .sheet(isPresented: $showEditSheet) {
      EditEarmarkSheet(
        earmark: earmark,
        onUpdate: { updated in
          Task {
            _ = await earmarkStore.update(updated)
            showEditSheet = false
          }
        }
      )
    }
  }

  private var overviewPanel: some View {
    VStack(spacing: 12) {
      summaryRow
      if let goal = earmark.savingsGoal, goal.isPositive {
        savingsProgress(goal: goal)
      }
    }
    .padding()
  }

  private var summaryRow: some View {
    HStack(spacing: 24) {
      summaryItem(
        label: "Balance",
        amount: earmarkStore.convertedBalance(for: earmark.id)
          ?? .zero(instrument: earmark.instrument))
      Divider().frame(maxHeight: 32)
      summaryItem(
        label: "Saved",
        amount: earmarkStore.convertedSaved(for: earmark.id)
          ?? .zero(instrument: earmark.instrument))
      Divider().frame(maxHeight: 32)
      summaryItem(
        label: "Spent",
        amount:
          -(earmarkStore.convertedSpent(for: earmark.id)
          ?? .zero(instrument: earmark.instrument)))
    }
  }

  private func savingsProgress(goal: InstrumentAmount) -> some View {
    let balance =
      earmarkStore.convertedBalance(for: earmark.id) ?? .zero(instrument: earmark.instrument)
    let progress =
      balance.isPositive
      ? Double(truncating: (balance.quantity / goal.quantity) as NSDecimalNumber)
      : 0.0
    let percentComplete = Int(min(progress, 1.0) * 100)
    return VStack(spacing: 4) {
      ProgressView(value: min(progress, 1.0)) {
        HStack {
          Text("Savings Goal").font(.caption)
          Spacer()
          InstrumentAmountView(amount: balance).font(.caption)
          Text("of").font(.caption).foregroundStyle(.secondary)
          InstrumentAmountView(amount: goal).font(.caption)
        }
      }
      .tint(progress >= 1.0 ? .green : .blue)
      .accessibilityLabel(
        "Savings goal: \(balance.formatted) of \(goal.formatted), "
          + "\(percentComplete)% complete"
      )
      savingsDateRow
    }
    .accessibilityElement(children: .combine)
  }

  private func summaryItem(
    label: String, amount: InstrumentAmount, colorOverride: Color? = nil
  ) -> some View {
    VStack(spacing: 2) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
      InstrumentAmountView(amount: amount, colorOverride: colorOverride)
        .font(.headline)
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder private var savingsDateRow: some View {
    let hasStart = earmark.savingsStartDate != nil
    let hasEnd = earmark.savingsEndDate != nil

    if hasStart || hasEnd {
      HStack {
        if let start = earmark.savingsStartDate {
          Label(start.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if hasStart && hasEnd {
          Image(systemName: "arrow.right")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
        }

        if let end = earmark.savingsEndDate {
          Label(end.formatted(date: .abbreviated, time: .omitted), systemImage: "flag")
            .font(.caption)
            .foregroundStyle(.secondary)

          if let remaining = timeRemaining(until: end) {
            Spacer()
            Text(remaining)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        if !hasEnd {
          Spacer()
        }
      }
    }
  }

  /// `now` is defaulted to the current clock at the boundary so production
  /// callers stay terse; tests can pin a specific date for the
  /// "Past due" / "Due today" / "N days left" branches.
  private func timeRemaining(until endDate: Date, now: Date = Date()) -> String? {
    guard endDate > now else { return "Past due" }

    let components = Calendar.current.dateComponents([.day], from: now, to: endDate)
    guard let days = components.day else { return nil }

    if days == 0 { return "Due today" }
    if days == 1 { return "1 day left" }
    if days < 30 { return "\(days) days left" }
    let months = days / 30
    if months == 1 { return "~1 month left" }
    return "~\(months) months left"
  }
}

@MainActor
private func seedEarmarkDetailPreview(
  backend: any BackendProvider,
  earmark: Earmark,
  earmarkStore: EarmarkStore,
  store: TransactionStore
) async {
  let accountId = UUID()
  _ = try? await backend.accounts.create(
    Account(id: accountId, name: "Test", type: .bank, instrument: .AUD))
  _ = try? await backend.earmarks.create(earmark)
  _ = try? await backend.transactions.create(
    Transaction(
      date: Date(),
      payee: "Flight Booking",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: .AUD,
          quantity: -50.23,
          type: .expense,
          earmarkId: earmark.id)
      ]))
  _ = try? await backend.transactions.create(
    Transaction(
      date: Date().addingTimeInterval(-86400),
      payee: "Savings Transfer",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: .AUD,
          quantity: 500,
          type: .income,
          earmarkId: earmark.id)
      ]))
  // No `earmarkStore.load()` — the reactive store subscribes in init.
  await store.load(filter: TransactionFilter(earmarkId: earmark.id))
}

private func previewEarmark() -> Earmark {
  Earmark(
    id: UUID(),
    name: "Holiday Fund",
    instrument: .AUD,
    savingsGoal: InstrumentAmount(quantity: 5000, instrument: .AUD),
    savingsStartDate: Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 1)),
    savingsEndDate: Calendar.current.date(from: DateComponents(year: 2026, month: 12, day: 31)))
}

#Preview {
  let earmark = previewEarmark()
  let backend = PreviewBackend.create()
  let earmarkStore = EarmarkStore(
    repository: backend.earmarks,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)
  let store = TransactionStore(
    repository: backend.transactions,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)
  return NavigationStack {
    EarmarkDetailView(
      earmark: earmark,
      accounts: Accounts(from: []),
      categories: Categories(from: []),
      earmarks: Earmarks(from: []),
      transactionStore: store,
      analysisRepository: backend.analysis
    )
    .environment(earmarkStore)
  }
  .previewProfileEnvironment()
  .task {
    await seedEarmarkDetailPreview(
      backend: backend, earmark: earmark, earmarkStore: earmarkStore, store: store)
  }
}
