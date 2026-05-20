import Foundation

struct Transaction: Codable, Sendable, Identifiable, Hashable {
  let id: UUID
  var date: Date
  var payee: String?
  var notes: String?
  var recurPeriod: RecurPeriod?
  var recurEvery: Int?
  var legs: [TransactionLeg]
  var importOrigin: TransactionImportOrigin?

  var isScheduled: Bool {
    recurPeriod != nil
  }

  var isRecurring: Bool {
    guard let period = recurPeriod else { return false }
    return period != .once
  }

  init(
    id: UUID = UUID(),
    date: Date,
    payee: String? = nil,
    notes: String? = nil,
    recurPeriod: RecurPeriod? = nil,
    recurEvery: Int? = nil,
    legs: [TransactionLeg],
    importOrigin: TransactionImportOrigin? = nil
  ) {
    self.id = id
    self.date = date
    self.payee = payee
    self.notes = notes
    self.recurPeriod = recurPeriod
    self.recurEvery = recurEvery
    self.legs = legs
    self.importOrigin = importOrigin
  }

  // MARK: - Convenience Accessors

  var accountIds: Set<UUID> { Set(legs.compactMap(\.accountId)) }
  var isTransfer: Bool {
    let accounts = Set(legs.filter { $0.type == .transfer }.compactMap(\.accountId))
    let instruments = Set(legs.filter { $0.type == .transfer }.map(\.instrument))
    return accounts.count > 1 || instruments.count > 1
  }

  // MARK: - Structure Queries (simple/transfer shape)

  /// Whether this transaction has simple structure: a single leg, or exactly
  /// two legs forming a basic transfer (amounts negate, same type, second leg
  /// has no category/earmark, and legs reference different accounts).
  var isSimple: Bool {
    if legs.count <= 1 { return true }
    guard legs.count == 2 else { return false }
    let first = legs[0]
    let second = legs[1]
    return first.quantity == -second.quantity
      && first.type == second.type
      && second.categoryId == nil
      && second.earmarkId == nil
      && first.accountId != second.accountId
  }

  /// Whether this transaction is a simple cross-currency transfer: exactly two
  /// transfer legs with different accounts and different instruments. Unlike
  /// `isSimple`, this does not require amounts to negate (since exchange rates
  /// mean the quantities will differ).
  var isSimpleCrossCurrencyTransfer: Bool {
    guard legs.count == 2 else { return false }
    let first = legs[0]
    let second = legs[1]
    guard first.type == .transfer && second.type == .transfer else { return false }
    guard let firstAcct = first.accountId, let secondAcct = second.accountId,
      firstAcct != secondAcct
    else { return false }
    guard second.categoryId == nil && second.earmarkId == nil else { return false }
    return first.instrument != second.instrument
  }

}

// MARK: - Spam Classification

extension Transaction {
  /// Whether every leg of this transaction references an instrument in
  /// the supplied spam set. Returns `false` for a transaction with zero
  /// legs — defensive, since an empty `allSatisfy` would otherwise
  /// return `true` and quietly hide an unexpected shape.
  ///
  /// This is deliberately *stricter* than the row-level "⚠️ Spam"
  /// indicator (`legs.contains { spamInstruments.contains($0.instrument) }`):
  /// the indicator informs the user that *any* leg touched spam, while
  /// this predicate gates the hide rule that *removes* the transaction
  /// from the list. Mixed-leg transactions affected a real balance and
  /// must remain visible. See
  /// `plans/2026-05-20-hide-spam-transactions-design.md` §"Definition".
  func isAllSpam(in spamInstruments: Set<Instrument>) -> Bool {
    !legs.isEmpty && legs.allSatisfy { spamInstruments.contains($0.instrument) }
  }
}
