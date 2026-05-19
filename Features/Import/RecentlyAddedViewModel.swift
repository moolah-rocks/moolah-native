import Foundation
import OSLog
import Observation

/// Drives the Recently Added view. Thin wrapper around the transactions
/// repository that filters by `ImportOrigin.importedAt` within the chosen
/// window and groups by `importSessionId`.
@Observable
@MainActor
final class RecentlyAddedViewModel {

  enum Window: String, CaseIterable, Identifiable, Sendable {
    case last24Hours
    case last3Days
    case lastWeek
    case last2Weeks
    case lastMonth
    case all

    var id: String { rawValue }

    var label: String {
      switch self {
      case .last24Hours: return "Last 24 hours"
      case .last3Days: return "Last 3 days"
      case .lastWeek: return "Last week"
      case .last2Weeks: return "Last 2 weeks"
      case .lastMonth: return "Last month"
      case .all: return "All"
      }
    }

    func dateRange(now: Date = Date()) -> ClosedRange<Date>? {
      let day: TimeInterval = 86_400
      switch self {
      case .last24Hours: return (now.addingTimeInterval(-day))...now
      case .last3Days: return (now.addingTimeInterval(-3 * day))...now
      case .lastWeek: return (now.addingTimeInterval(-7 * day))...now
      case .last2Weeks: return (now.addingTimeInterval(-14 * day))...now
      case .lastMonth: return (now.addingTimeInterval(-30 * day))...now
      case .all: return nil
      }
    }
  }

  /// A group of transactions imported in the same session.
  struct SessionGroup: Identifiable, Sendable {
    let id: UUID
    let importedAt: Date
    let filenames: [String]
    let transactions: [Transaction]

    /// v1 proxy for "needs review": any transaction whose legs all lack a
    /// category. See the design doc.
    var needsReviewCount: Int {
      transactions.filter { $0.needsReview }.count
    }
  }

  private(set) var window: Window = .last24Hours
  private(set) var sessions: [SessionGroup] = []
  private(set) var badgeCount: Int = 0
  private(set) var isLoading = false

  /// Repository-backed snapshot of the suggestions touching any loaded
  /// transaction, keyed by member transaction id. Refreshed by `load`
  /// alongside `sessions`. The pill / counterpart lookups read this
  /// synced-record snapshot, so the row stays a thin renderer and the
  /// view never touches the repository directly.
  private var suggestionsByTransactionId: [UUID: TransferSuggestion] = [:]

  private let backend: any BackendProvider
  private let logger = Logger(
    subsystem: "com.moolah.app", category: "RecentlyAddedViewModel")

  init(backend: any BackendProvider) {
    self.backend = backend
  }

  func load(window: Window, now: Date = Date()) async {
    guard !isLoading else { return }
    self.window = window
    isLoading = true
    defer { isLoading = false }
    let pageSize = 500
    var all: [Transaction] = []
    do {
      var page = 0
      while true {
        let result = try await backend.transactions.fetch(
          filter: TransactionFilter(),
          page: page,
          pageSize: pageSize)
        if result.transactions.isEmpty { break }
        all.append(contentsOf: result.transactions)
        if result.transactions.count < pageSize { break }
        page += 1
        // Safety cap: don't fetch more than 5 pages to keep the view snappy
        // (2500 transactions max). Windowed recent views never need more.
        if page >= 5 { break }
      }
    } catch {
      logger.error("load failed: \(error.localizedDescription, privacy: .public)")
    }

    let filtered = Self.filter(all, window: window, now: now)
    sessions = Self.group(filtered)
    badgeCount = filtered.filter { $0.needsReview }.count
    await loadSuggestionSnapshot()
  }

  /// Rebuilds `suggestionsByTransactionId` from the synced
  /// `TransferSuggestion` records. Each suggestion is indexed under
  /// both of its member transaction ids so the row lookups are O(1).
  /// A failure leaves the snapshot empty (no pills) rather than
  /// crashing the view — the records re-converge on the next load.
  private func loadSuggestionSnapshot() async {
    do {
      let all = try await backend.transferSuggestions.fetchAll()
      var byId: [UUID: TransferSuggestion] = [:]
      for suggestion in all {
        for transactionId in suggestion.transactionIds {
          byId[transactionId] = suggestion
        }
      }
      suggestionsByTransactionId = byId
    } catch {
      logger.error(
        "suggestion snapshot load failed: \(error.localizedDescription, privacy: .public)")
      suggestionsByTransactionId = [:]
    }
  }

  /// Exposed for tests and for the sidebar badge lookup — given a fully-fetched
  /// transaction list, return only those with an ImportOrigin within the
  /// window.
  static func filter(
    _ transactions: [Transaction],
    window: Window,
    now: Date = Date()
  ) -> [Transaction] {
    transactions.filter { transaction in
      // Recently Added groups by single-import session; .merged transfers
      // (which have no single origin) are excluded.
      guard let origin = transaction.importOrigin?.singleOrigin else { return false }
      if let range = window.dateRange(now: now) {
        return range.contains(origin.importedAt)
      }
      return true
    }
  }

  /// Whether a `TransferSuggestion` record touches `transaction` in the
  /// current snapshot. Drives the passive "possible transfer" pill.
  func hasSuggestion(_ transaction: Transaction) -> Bool {
    suggestionsByTransactionId[transaction.id] != nil
  }

  /// The counterpart transaction for a detected transfer suggestion,
  /// resolved through the synced-record snapshot and against the
  /// currently-loaded sessions. `nil` when no suggestion record touches
  /// `transaction` or the counterpart is outside the loaded window.
  func counterpart(of transaction: Transaction) -> Transaction? {
    guard
      let suggestion = suggestionsByTransactionId[transaction.id],
      let counterpartId = suggestion.counterpart(of: transaction.id)
    else { return nil }
    for group in sessions {
      if let match = group.transactions.first(where: { $0.id == counterpartId }) {
        return match
      }
    }
    return nil
  }

  /// Label for the passive "possible transfer" pill (also the VoiceOver
  /// label). `counterpartAccountName` is resolved by the view from the
  /// loaded account list — when the counterpart account was deleted
  /// between detection and display it is `nil` and the generic fallback
  /// is used.
  func pillTitle(counterpartAccountName: String?) -> String {
    if let name = counterpartAccountName, !name.isEmpty {
      return "Possible transfer to \(name)"
    }
    return "Possible transfer"
  }

  /// Resolve the counterpart account's display name from the supplied
  /// account list. Returns `nil` when the transaction carries no
  /// counterpart, the counterpart has no value leg, or the account was
  /// deleted between detection and display (the pill then uses the
  /// generic title). The value leg is the first leg — the same source
  /// leg the row's amount is derived from.
  func counterpartAccountName(of transaction: Transaction, accounts: Accounts) -> String? {
    guard let counterpart = counterpart(of: transaction),
      let accountId = counterpart.legs.first?.accountId,
      let account = accounts.by(id: accountId)
    else { return nil }
    return account.name
  }

  /// Spoken VoiceOver label for one imported-transaction row. Combines
  /// the payee (or import description), the formatted date, the formatted
  /// amount, and — when present — the pill title and a "Needs review"
  /// note, joined by ", ". The amount uses the same instrument formatting
  /// the visible `InstrumentAmountView` speaks for non-spam amounts, and
  /// the date uses the same day/month/year style the row renders.
  func rowAccessibilityLabel(
    for transaction: Transaction,
    counterpartAccountName: String?
  ) -> String {
    var parts: [String] = []
    let primary =
      transaction.payee
      ?? transaction.importOrigin?.singleOrigin?.rawDescription
    if let primary, !primary.isEmpty {
      parts.append(primary)
    }
    parts.append(
      transaction.date.formatted(.dateTime.day().month().year()))
    if let leg = transaction.legs.first {
      let amount = InstrumentAmount(quantity: leg.quantity, instrument: leg.instrument)
      parts.append(amount.accessibilityString(isSpam: false))
    }
    if hasSuggestion(transaction) {
      parts.append(pillTitle(counterpartAccountName: counterpartAccountName))
    }
    if transaction.needsReview {
      parts.append("Needs review")
    }
    return parts.joined(separator: ", ")
  }

  static func group(_ transactions: [Transaction]) -> [SessionGroup] {
    let dict = Dictionary(
      grouping: transactions,
      by: { $0.importOrigin?.singleOrigin?.importSessionId ?? UUID() })
    return dict.map { id, txs in
      let filenames = Array(
        Set(txs.compactMap { $0.importOrigin?.singleOrigin?.sourceFilename })
      ).sorted()
      let importedAt =
        txs.map { $0.importOrigin?.singleOrigin?.importedAt ?? .distantPast }.max()
        ?? .distantPast
      return SessionGroup(
        id: id,
        importedAt: importedAt,
        filenames: filenames,
        transactions: txs.sorted { $0.date > $1.date })
    }.sorted { $0.importedAt > $1.importedAt }
  }
}
