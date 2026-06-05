import Foundation
import OSLog

private let logger = Logger(subsystem: "com.moolah.app", category: "AutomationService")

/// Tri-state change to an account's `isHidden` flag used by
/// `AutomationService.updateAccount(...)`. Replaces a `Bool?` so an
/// "unchanged" intent can't be confused with "set to false" at call sites
/// and keeps SwiftLint's `discouraged_optional_boolean` rule satisfied.
enum AccountHiddenChange: Sendable {
  case unchanged
  case setTo(Bool)
}

/// Describes a partial update to an account. Fields left `nil` / `.unchanged`
/// are preserved; set fields are applied.
struct AccountChanges: Sendable {
  var name: String?
  var hidden: AccountHiddenChange

  init(name: String? = nil, hidden: AccountHiddenChange = .unchanged) {
    self.name = name
    self.hidden = hidden
  }
}

@MainActor
final class AutomationService {
  let sessionManager: SessionManager

  init(sessionManager: SessionManager) {
    self.sessionManager = sessionManager
  }

  /// Resolves a profile session by name (case-insensitive) or UUID string.
  func resolveSession(for identifier: String) throws -> ProfileSession {
    if let session = sessionManager.session(named: identifier) { return session }
    if let uuid = UUID(uuidString: identifier),
      let session = sessionManager.session(forID: uuid)
    {
      return session
    }
    throw AutomationError.profileNotFound(identifier)
  }

  /// Returns all currently open profiles.
  func listOpenProfiles() -> [Profile] {
    sessionManager.openProfiles.map(\.profile)
  }

  // MARK: - Transaction Operations

  /// Describes a single leg of a transaction for creation.
  struct LegSpec: Sendable {
    let accountName: String
    let amount: Decimal
    let categoryName: String?
    let earmarkName: String?
  }

  /// Creates a transaction with the specified legs.
  func createTransaction(
    profileIdentifier: String,
    payee: String,
    date: Date,
    legs: [LegSpec],
    notes: String? = nil
  ) async throws -> Transaction {
    let session = try resolveSession(for: profileIdentifier)
    let instrument = session.profile.instrument

    let resolution = try await resolveLegs(
      legs, profileIdentifier: profileIdentifier, instrument: instrument)
    let finalLegs = normaliseTransferLegs(resolution.legs, accountIds: resolution.accountIds)

    let transaction = Transaction(
      id: UUID(),
      date: date,
      payee: payee,
      notes: notes,
      recurPeriod: nil,
      recurEvery: nil,
      legs: finalLegs
    )

    guard let created = await session.transactionStore.create(transaction) else {
      throw AutomationError.operationFailed("Failed to create transaction")
    }
    return created
  }

  private func resolveLegs(
    _ legs: [LegSpec], profileIdentifier: String, instrument: Instrument
  ) async throws -> (legs: [TransactionLeg], accountIds: Set<UUID>) {
    // Fetch the authoritative account snapshot once and resolve every leg
    // against it (see `resolveAccount(named:)` for why this is a
    // repository read rather than a reactive-store read).
    let accounts = try await fetchAccounts(profileIdentifier: profileIdentifier)
    var resolvedLegs: [TransactionLeg] = []
    var accountIds = Set<UUID>()
    for spec in legs {
      let account = try Self.account(named: spec.accountName, in: accounts)
      accountIds.insert(account.id)

      let categoryId: UUID? =
        if let categoryName = spec.categoryName {
          try resolveCategory(named: categoryName, profileIdentifier: profileIdentifier).id
        } else {
          nil
        }

      let earmarkId: UUID? =
        if let earmarkName = spec.earmarkName {
          try resolveEarmark(named: earmarkName, profileIdentifier: profileIdentifier).id
        } else {
          nil
        }

      let legType: TransactionType = spec.amount >= 0 ? .income : .expense
      resolvedLegs.append(
        TransactionLeg(
          accountId: account.id,
          instrument: instrument,
          quantity: spec.amount,
          type: legType,
          categoryId: categoryId,
          earmarkId: earmarkId
        ))
    }
    return (resolvedLegs, accountIds)
  }

  private func normaliseTransferLegs(
    _ legs: [TransactionLeg], accountIds: Set<UUID>
  ) -> [TransactionLeg] {
    // Transfers (2+ legs with different accounts) use .expense type on every leg.
    guard accountIds.count > 1 else { return legs }
    return legs.map { leg in
      var copy = leg
      copy.type = .expense
      return copy
    }
  }

  /// Lists transactions, optionally filtered by account name and/or scheduled status.
  func listTransactions(
    profileIdentifier: String,
    accountName: String? = nil,
    scheduled: ScheduledFilter = .all
  ) async throws -> [Transaction] {
    let session = try resolveSession(for: profileIdentifier)

    var filter = TransactionFilter()
    if let accountName {
      let account = try await resolveAccount(
        named: accountName, profileIdentifier: profileIdentifier)
      filter.accountId = account.id
    }
    filter.scheduled = scheduled

    await session.transactionStore.load(filter: filter)
    return session.transactionStore.transactions.map(\.transaction)
  }

  /// Updates an existing transaction's payee, date, or notes.
  func updateTransaction(
    profileIdentifier: String,
    transactionId: UUID,
    payee: String? = nil,
    date: Date? = nil,
    notes: String? = nil
  ) async throws -> Transaction {
    let session = try resolveSession(for: profileIdentifier)

    // Find the transaction in the store
    guard
      let entry = session.transactionStore.transactions.first(where: {
        $0.transaction.id == transactionId
      })
    else {
      throw AutomationError.transactionNotFound(transactionId.uuidString)
    }

    var transaction = entry.transaction
    if let payee { transaction.payee = payee }
    if let date { transaction.date = date }
    if let notes { transaction.notes = notes }

    await session.transactionStore.update(transaction)

    // Return the updated version from the store
    guard
      let updated = session.transactionStore.transactions.first(where: {
        $0.transaction.id == transactionId
      })
    else {
      throw AutomationError.operationFailed("Transaction update failed")
    }
    return updated.transaction
  }

  /// Deletes a transaction by UUID.
  func deleteTransaction(profileIdentifier: String, transactionId: UUID) async throws {
    let session = try resolveSession(for: profileIdentifier)
    await session.transactionStore.delete(id: transactionId)
  }

  /// Deletes every transaction with a leg on the named account so a
  /// subsequent `synchronize` re-imports it from scratch. Per-leg dedup is
  /// keyed on `(accountId, externalId)`; with the prior legs gone the next
  /// sync rebuilds the account cleanly. Testing aid for synced (crypto /
  /// exchange) accounts after an import-logic change. Returns the number of
  /// transactions deleted.
  @discardableResult
  func resetImportedTransactions(
    profileIdentifier: String, accountName: String
  ) async throws -> Int {
    let transactions = try await listTransactions(
      profileIdentifier: profileIdentifier, accountName: accountName)
    let session = try resolveSession(for: profileIdentifier)
    for transaction in transactions {
      await session.transactionStore.delete(id: transaction.id)
    }
    return transactions.count
  }

  /// Pays a scheduled transaction (creates a non-scheduled copy with today's date).
  func payScheduledTransaction(
    profileIdentifier: String,
    transactionId: UUID
  ) async throws -> TransactionStore.PayResult {
    let session = try resolveSession(for: profileIdentifier)

    guard
      let entry = session.transactionStore.transactions.first(where: {
        $0.transaction.id == transactionId
      })
    else {
      throw AutomationError.transactionNotFound(transactionId.uuidString)
    }

    return await session.transactionStore.payScheduledTransaction(entry.transaction)
  }

}
