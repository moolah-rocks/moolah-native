import OSLog
import SwiftUI

/// Tracks the first time the Analysis Dashboard's Upcoming card paints with
/// data after launch. Logged once per process to `Perf.UpcomingCard` so
/// before/after benchmarks can read the cold-load latency directly from the
/// log stream.
///
/// `MoolahApp.init` calls `anchorLaunchTime()` so `launchTime` resolves at
/// process start instead of lazily on first card render — without that anchor
/// the elapsed measurement collapses to zero. See
/// `plans/2026-04-27-upcoming-card-cold-load-plan.md`.
@MainActor
enum UpcomingFirstPaintTracker {
  private static let launchTime = ContinuousClock.now
  private static var didLog = false
  private static let logger = Logger(
    subsystem: "com.moolah.app", category: "Perf.UpcomingCard")

  /// Force `launchTime` to initialize now. No-op if already initialized.
  static func anchorLaunchTime() {
    _ = launchTime
  }

  /// Logs the first-paint elapsed time exactly once per process. Subsequent
  /// calls are no-ops, so it's safe to invoke from a `.task(id:)` body that
  /// re-fires on count changes.
  static func logFirstPaintIfNeeded(count: Int) {
    guard !didLog else { return }
    didLog = true
    let elapsedMs = (ContinuousClock.now - launchTime).inMilliseconds
    logger.log(
      """
      📊 first-paint of upcoming card: \(elapsedMs, privacy: .public)ms \
      (count: \(count, privacy: .public))
      """)
  }
}

struct UpcomingTransactionsCard: View {
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let transactionStore: TransactionStore
  @Binding var selectedTransaction: Transaction?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Upcoming & Overdue")
        .font(.title2)
        .fontWeight(.semibold)

      if shortTermTransactions.isEmpty {
        emptyState
      } else {
        transactionList
          .task(id: shortTermTransactions.count) {
            UpcomingFirstPaintTracker.logFirstPaintIfNeeded(
              count: shortTermTransactions.count)
          }
      }
    }
    .padding()
    .background(.background)
    .clipShape(.rect(cornerRadius: 12))
    #if os(macOS)
      .frame(maxHeight: .infinity, alignment: .top)
    #endif
  }

  private var emptyState: some View {
    ContentUnavailableView(
      "No Upcoming Transactions",
      systemImage: "calendar",
      description: Text("No overdue or scheduled transactions due in the next 14 days.")
    )
    .frame(maxHeight: 200)
  }

  private var transactionList: some View {
    listContent
  }

  private var listContent: some View {
    List(selection: $selectedTransaction) {
      ForEach(shortTermTransactions) { txn in
        SimpleTransactionRow(
          transaction: txn.transaction,
          accounts: accounts,
          earmarks: earmarks,
          displayAmount: txn.displayAmount,
          isOverdue: isOverdue(txn.transaction),
          isDueToday: isDueToday(txn.transaction)
        ) {
          await payTransaction(txn.transaction)
        }
        .tag(txn.transaction)
        .contentShape(Rectangle())
      }
    }
    #if os(macOS)
      .listStyle(.inset)
    #else
      .listStyle(.plain)
    #endif
    #if os(macOS)
      .frame(minHeight: 200)
    #else
      // Dynamic frame instead of a fixed 200pt: at larger Dynamic Type
      // sizes individual rows grow taller and a fixed 200 would clip to
      // one or two rows. The cap keeps the card from dominating the
      // screen on very large Dynamic Type settings.
      .frame(minHeight: 200, maxHeight: 400)
    #endif
    // Tighter row height for this dense upcoming context — the
    // analysis dashboard packs several cards onto one screen and the
    // default 44pt row height eats too much vertical space for a
    // five- or six-row glance card.
    .environment(\.defaultMinListRowHeight, 40)
    .accessibilityLabel("List of upcoming and overdue transactions")
  }

  private var shortTermTransactions: [TransactionWithBalance] {
    transactionStore.scheduledShortTermTransactions()
  }

  private func isOverdue(_ transaction: Transaction) -> Bool {
    transaction.date < Calendar.current.startOfDay(for: Date())
  }

  private func isDueToday(_ transaction: Transaction) -> Bool {
    Calendar.current.isDateInToday(transaction.date)
  }

  private func payTransaction(_ scheduledTransaction: Transaction) async {
    _ = await transactionStore.payScheduledTransaction(scheduledTransaction)
  }
}

private struct SimpleTransactionRow: View {
  let transaction: Transaction
  let accounts: Accounts
  let earmarks: Earmarks
  let displayAmount: InstrumentAmount?
  let isOverdue: Bool
  let isDueToday: Bool
  let onPay: () async -> Void

  @State private var isPaying = false

  var body: some View {
    HStack(spacing: 12) {
      payeeColumn
      Spacer()
      if let displayAmount {
        InstrumentAmountView(amount: displayAmount, font: .body)
      } else {
        Text("—")
          .font(.body)
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      payButton
    }
    .padding(.vertical, 4)
  }

  private var payeeColumn: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 4) {
        if isOverdue {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .imageScale(.small)
            .accessibilityLabel("Overdue")
        }
        Text(displayPayee)
          .font(.body)
          .fontWeight(.medium)
          .foregroundStyle(isOverdue ? .red : .primary)
      }
      recurrenceRow
    }
  }

  private var recurrenceRow: some View {
    HStack(spacing: 8) {
      Text(transaction.date, format: .dateTime.month().day())
        .font(.caption)
        .foregroundStyle(isDueToday ? .orange : .secondary)
        .fontWeight(isDueToday ? .semibold : .regular)
        .monospacedDigit()
      if let recurPeriod = transaction.recurPeriod,
        let recurEvery = transaction.recurEvery,
        recurPeriod != .once
      {
        Text("•").foregroundStyle(.secondary)
        Text(recurPeriod.recurrenceDescription(every: recurEvery))
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityLabel(
            "Repeats \(recurPeriod.recurrenceDescription(every: recurEvery))")
      }
    }
  }

  private var payButton: some View {
    Button {
      Task {
        isPaying = true
        await onPay()
        isPaying = false
      }
    } label: {
      if isPaying {
        ProgressView().controlSize(.small)
      } else {
        Text("Pay")
      }
    }
    #if os(macOS)
      .buttonStyle(.bordered)
    #else
      .buttonStyle(.borderedProminent)
    #endif
    .controlSize(.small)
    .disabled(isPaying)
    .accessibilityLabel("Pay \(displayPayee)")
  }

  private var displayPayee: String {
    let label = transaction.displayPayee(
      accountContext: nil, accounts: accounts, earmarks: earmarks)
    return label.isEmpty ? "Unknown" : label
  }
}

#Preview {
  let backend = PreviewBackend.create()
  let store = TransactionStore(
    repository: backend.transactions,
    conversionService: backend.conversionService,
    targetInstrument: .AUD
  )

  return UpcomingTransactionsCard(
    accounts: Accounts(from: []),
    categories: Categories(from: []),
    earmarks: Earmarks(from: []),
    transactionStore: store,
    selectedTransaction: .constant(nil)
  )
  .frame(width: 400)
  .padding()
  .task { await seedUpcomingPreview(backend: backend, store: store) }
}

@MainActor
private func seedUpcomingPreview(backend: any BackendProvider, store: TransactionStore) async {
  let account = Account(id: UUID(), name: "Test Account", type: .bank, instrument: .AUD)
  _ = try? await backend.accounts.create(
    account,
    openingBalance: InstrumentAmount(quantity: 1000, instrument: .AUD))
  _ = try? await backend.transactions.create(
    Transaction(
      id: UUID(),
      date: Date().addingTimeInterval(86400 * 2),
      payee: "Utility Bill",
      recurPeriod: .month,
      recurEvery: 1,
      legs: [
        TransactionLeg(accountId: account.id, instrument: .AUD, quantity: -50, type: .expense)
      ]))
  _ = try? await backend.transactions.create(
    Transaction(
      id: UUID(),
      date: Date().addingTimeInterval(86400 * 7),
      payee: "Paycheck",
      recurPeriod: .week,
      recurEvery: 2,
      legs: [
        TransactionLeg(accountId: account.id, instrument: .AUD, quantity: 2000, type: .income)
      ]))
  await store.load(filter: TransactionFilter(scheduled: .scheduledOnly))
}
