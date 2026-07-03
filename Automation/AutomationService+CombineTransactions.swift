import Foundation

// General N-way transaction merge for `AutomationService`: collapse two
// or more same-day, same-payee transactions into one whose legs are the
// union of the sources' legs. The AppleScript counterpart to the list's
// "Merge Transactions" command; distinct from `mergeTransactions`, which
// is the two-transaction transfer merge. Reuses `TransactionMergeBuilder`
// so both surfaces enforce identical validity rules. The member is
// `@MainActor` via the containing class.
extension AutomationService {
  /// Combines the referenced transactions into one merged transaction.
  ///
  /// Every id is resolved from the authoritative repository snapshot.
  /// The selection must be a valid general merge (two or more, same
  /// calendar day, same payee, none scheduled) or the merge throws. The
  /// sources are deleted and the merged transaction inserted atomically.
  ///
  /// Each leg is carried through unchanged, including its `externalId`
  /// (the dedup key the wallet/exchange apply pass matches on
  /// `(accountId, externalId)`), so a merged sync-owned leg is not
  /// re-imported as a duplicate on the next sync.
  func combineTransactions(
    profileIdentifier: String,
    ids: [UUID]
  ) async throws -> Transaction {
    let session = try resolveSession(for: profileIdentifier)

    let transactions = try await session.backend.transactions.fetchAll(
      filter: TransactionFilter())
    let sources = try ids.map { try Self.transaction(id: $0, in: transactions) }

    let merged: Transaction
    do {
      merged = try TransactionMergeBuilder().merged(sources)
    } catch {
      throw AutomationError.operationFailed("Cannot merge: \(error.localizedDescription)")
    }

    do {
      let created = try await session.backend.transactions.replace(
        deletingIds: ids, creating: [merged])
      guard let result = created.first else {
        throw AutomationError.operationFailed("Merge produced no transaction")
      }
      return result
    } catch let error as AutomationError {
      throw error
    } catch {
      throw AutomationError.operationFailed(
        "Failed to merge transactions: \(error.localizedDescription)")
    }
  }
}
