import Foundation

// Transfer-merge operation for `AutomationService`: collapse two opposing
// single-account transactions into one cross-account transfer. Enables a
// script to re-match a hand-entered bank transfer against a synced exchange
// leg during a data migration. The member is `@MainActor` via the containing
// class.
extension AutomationService {

  /// Merges two single-account transactions into one cross-account transfer.
  ///
  /// Both ids are resolved from the authoritative repository snapshot. The
  /// pair must form a valid transfer (different accounts, same instrument,
  /// opposite-equal value legs) or the merge throws. The two sources are
  /// deleted and the merged transfer inserted atomically.
  ///
  /// Reuses `TransferMergeBuilder`, which carries each leg's `externalId`
  /// (and `counterpartyAddress`) through to the merged transfer leg. This is
  /// essential: `externalId` is the dedup key the wallet/exchange apply pass
  /// matches on `(accountId, externalId)`, so a merged sync-owned leg that
  /// kept its `externalId` is not re-imported as a duplicate on the next sync.
  func mergeTransactions(
    profileIdentifier: String,
    firstId: UUID,
    secondId: UUID
  ) async throws -> Transaction {
    let session = try resolveSession(for: profileIdentifier)

    let transactions = try await session.backend.transactions.fetchAll(filter: TransactionFilter())
    let first = try Self.transaction(id: firstId, in: transactions)
    let second = try Self.transaction(id: secondId, in: transactions)

    let merged: Transaction
    do {
      merged = try TransferMergeBuilder().merged(from: first, second)
    } catch {
      throw AutomationError.operationFailed(
        "Cannot merge: \(error.localizedDescription)")
    }

    do {
      let created = try await session.backend.transactions.replace(
        deletingIds: [firstId, secondId], creating: [merged])
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

  /// Finds a transaction by id within an already-fetched snapshot, throwing
  /// `transactionNotFound` when absent.
  private static func transaction(
    id: UUID, in transactions: [Transaction]
  ) throws -> Transaction {
    guard let transaction = transactions.first(where: { $0.id == id }) else {
      throw AutomationError.transactionNotFound(id.uuidString)
    }
    return transaction
  }
}
