import Foundation

/// Pure merge transform combining two or more transactions into one.
/// No I/O.
///
/// The N source transactions must share the same calendar day and the
/// same payee, and none may be scheduled/recurring. Every leg of every
/// source is carried through unchanged (identity fields intact); the
/// merged transaction takes the earliest source date, the shared payee,
/// and the sources' notes newline-joined with duplicate lines dropped.
/// `importOrigin` is dropped — it has no meaning across N arbitrary
/// transactions, and each leg keeps its own `externalId` so sync dedup
/// (`(accountId, externalId)`) stays correct. The merge is one-way; no
/// per-source provenance is recorded.
struct TransactionMergeBuilder: Sendable {
  func merged(_ transactions: [Transaction]) throws -> Transaction {
    guard transactions.count >= 2 else { throw TransactionMergeError.tooFewTransactions }
    let first = transactions[0]
    guard transactions.allSatisfy({ $0.payee == first.payee }) else {
      throw TransactionMergeError.differentPayees
    }
    guard transactions.allSatisfy({ $0.date.isSameDay(as: first.date) }) else {
      throw TransactionMergeError.differentDays
    }
    guard transactions.allSatisfy({ $0.recurPeriod == nil }) else {
      throw TransactionMergeError.containsScheduled
    }

    return Transaction(
      date: transactions.map(\.date).min() ?? first.date,
      payee: first.payee,
      notes: mergedNotes(transactions.map(\.notes)),
      legs: transactions.flatMap(\.legs))
  }
}
