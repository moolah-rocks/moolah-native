import Foundation

// Transaction operations for `AutomationService`: create, list, query,
// update, delete, reset imports, and pay scheduled transactions.
// All members are `@MainActor` via the containing class.
extension AutomationService {
  struct FoundLeg: Sendable {
    let transaction: Transaction
    let leg: TransactionLeg
  }

  /// Describes a single leg of a transaction for creation.
  struct LegSpec: Sendable {
    let accountName: String
    let amount: Decimal
    let categoryName: String?
    let earmarkName: String?
  }

  struct ResolvedFindFilters: Sendable {
    let filter: TransactionFilter
    let accountId: UUID?
    let categoryId: UUID?
  }

  // MARK: - Transaction Operations

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

  /// Finds transactions through the repository query path for automation clients.
  func findTransactions(
    profileIdentifier: String,
    accountName: String? = nil,
    accountId: UUID? = nil,
    categoryName: String? = nil,
    categoryId: UUID? = nil,
    fromDate: Date? = nil,
    toDate: Date? = nil,
    scheduled: ScheduledFilter = .nonScheduledOnly
  ) async throws -> [Transaction] {
    let session = try resolveSession(for: profileIdentifier)
    let resolved = try await resolvedFindFilters(
      account: (name: accountName, id: accountId),
      category: (name: categoryName, id: categoryId),
      dates: (from: fromDate, to: toDate),
      scheduled: scheduled,
      profileIdentifier: profileIdentifier)

    do {
      return try await session.backend.transactions.fetchAll(filter: resolved.filter)
    } catch {
      throw AutomationError.operationFailed(
        "Failed to find transactions: \(error.localizedDescription)")
    }
  }

  /// Finds transaction legs through the repository query path for automation clients.
  func findLegs(
    profileIdentifier: String,
    accountName: String? = nil,
    accountId: UUID? = nil,
    categoryName: String? = nil,
    categoryId: UUID? = nil,
    fromDate: Date? = nil,
    toDate: Date? = nil,
    scheduled: ScheduledFilter = .nonScheduledOnly
  ) async throws -> [FoundLeg] {
    let session = try resolveSession(for: profileIdentifier)
    let resolved = try await resolvedFindFilters(
      account: (name: accountName, id: accountId),
      category: (name: categoryName, id: categoryId),
      dates: (from: fromDate, to: toDate),
      scheduled: scheduled,
      profileIdentifier: profileIdentifier)
    let transactions: [Transaction]
    do {
      transactions = try await session.backend.transactions.fetchAll(filter: resolved.filter)
    } catch {
      throw AutomationError.operationFailed(
        "Failed to find transactions: \(error.localizedDescription)")
    }

    return transactions.flatMap { transaction in
      transaction.legs.compactMap { leg in
        guard Self.leg(leg, matchesAccountId: resolved.accountId),
          Self.leg(leg, matchesCategoryId: resolved.categoryId)
        else {
          return nil
        }
        return FoundLeg(transaction: transaction, leg: leg)
      }
    }
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

    let transactions = try await session.backend.transactions.fetchAll(filter: TransactionFilter())
    guard var transaction = transactions.first(where: { $0.id == transactionId }) else {
      throw AutomationError.transactionNotFound(transactionId.uuidString)
    }

    if let payee { transaction.payee = payee }
    if let date { transaction.date = date }
    if let notes { transaction.notes = notes }

    do {
      return try await session.backend.transactions.update(transaction)
    } catch let error as AutomationError {
      throw error
    } catch {
      throw AutomationError.operationFailed(
        "Failed to update transaction: \(error.localizedDescription)")
    }
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

extension AutomationService {

  // MARK: - Leg Resolution Helpers

  fileprivate func resolveLegs(
    _ legs: [LegSpec], profileIdentifier: String, instrument: Instrument
  ) async throws -> (legs: [TransactionLeg], accountIds: Set<UUID>) {
    let accounts = try await fetchAccounts(profileIdentifier: profileIdentifier)
    let categories = try await fetchCategories(profileIdentifier: profileIdentifier)
    let earmarks = try await fetchEarmarks(profileIdentifier: profileIdentifier)
    var resolvedLegs: [TransactionLeg] = []
    var accountIds = Set<UUID>()
    for spec in legs {
      let account = try Self.account(named: spec.accountName, in: accounts)
      accountIds.insert(account.id)

      let categoryId: UUID? =
        if let categoryName = spec.categoryName {
          try Self.category(named: categoryName, in: categories).id
        } else {
          nil
        }

      let earmarkId: UUID? =
        if let earmarkName = spec.earmarkName {
          try Self.earmark(named: earmarkName, in: earmarks).id
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

  fileprivate func normaliseTransferLegs(
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

  // MARK: - Find Filter Helpers

  fileprivate func resolvedFindFilters(
    account: (name: String?, id: UUID?),
    category: (name: String?, id: UUID?),
    dates: (from: Date?, to: Date?),
    scheduled: ScheduledFilter,
    profileIdentifier: String
  ) async throws -> ResolvedFindFilters {
    var filter = TransactionFilter()
    let accountId = try await resolvedAccountId(
      name: account.name, id: account.id, profileIdentifier: profileIdentifier)
    let categoryId = try await resolvedCategoryId(
      name: category.name, id: category.id, profileIdentifier: profileIdentifier)
    filter.accountId = accountId
    if let categoryId {
      filter.categoryIds = [categoryId]
    }
    if let dateInterval = try findTransactionsDateInterval(
      fromDate: dates.from, toDate: dates.to)
    {
      filter.dateInterval = dateInterval
    }
    filter.scheduled = scheduled
    return ResolvedFindFilters(filter: filter, accountId: accountId, categoryId: categoryId)
  }

  fileprivate func resolvedAccountId(
    name: String?,
    id: UUID?,
    profileIdentifier: String
  ) async throws -> UUID? {
    guard name == nil || id == nil else {
      throw AutomationError.invalidParameter("Use either account or account id, not both.")
    }
    if let id {
      return try await resolveAccount(id: id, profileIdentifier: profileIdentifier).id
    }
    if let name {
      return try await resolveAccount(named: name, profileIdentifier: profileIdentifier).id
    }
    return nil
  }

  fileprivate func resolvedCategoryId(
    name: String?,
    id: UUID?,
    profileIdentifier: String
  ) async throws -> UUID? {
    guard name == nil || id == nil else {
      throw AutomationError.invalidParameter("Use either category or category id, not both.")
    }
    if let id {
      return try await resolveCategory(id: id, profileIdentifier: profileIdentifier).id
    }
    if let name {
      return try await resolveCategory(named: name, profileIdentifier: profileIdentifier).id
    }
    return nil
  }

  fileprivate func findTransactionsDateInterval(fromDate: Date?, toDate: Date?) throws -> Range<
    Date
  >? {
    guard fromDate != nil || toDate != nil else { return nil }

    let calendar = Calendar.current
    let lowerBound = fromDate.map { calendar.startOfDay(for: $0) } ?? .distantPast
    guard let toDate else { return lowerBound..<Date.distantFuture }
    let upperDayStart = calendar.startOfDay(for: toDate)
    guard let upperBound = calendar.date(byAdding: .day, value: 1, to: upperDayStart) else {
      throw AutomationError.invalidParameter("Could not resolve the upper date bound")
    }
    guard lowerBound < upperBound else {
      throw AutomationError.invalidParameter("from date must be on or before to date")
    }
    return lowerBound..<upperBound
  }

  fileprivate static func leg(_ leg: TransactionLeg, matchesAccountId accountId: UUID?) -> Bool {
    guard let accountId else { return true }
    return leg.accountId == accountId
  }

  fileprivate static func leg(_ leg: TransactionLeg, matchesCategoryId categoryId: UUID?) -> Bool {
    guard let categoryId else { return true }
    return leg.categoryId == categoryId
  }
}
