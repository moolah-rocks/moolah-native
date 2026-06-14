import Foundation

// Earmark / category / investment / analysis / refresh / crypto-sync
// handlers. All members are `@MainActor` via the containing class.
extension AutomationService {

  // MARK: - Earmark Operations

  /// Returns all earmarks for the given profile.
  func listEarmarks(profileIdentifier: String) throws -> [Earmark] {
    let session = try resolveSession(for: profileIdentifier)
    return Array(session.earmarkStore.earmarks)
  }

  /// Resolves an earmark by name (case-insensitive) within a profile.
  ///
  /// Reads the authoritative repository snapshot (`fetchAll()`) rather than
  /// the reactive `EarmarkStore.earmarks` — see
  /// `resolveAccount(named:profileIdentifier:)` for why automation needs a
  /// repository-direct read. A script (or single intent) creates an earmark
  /// and references it by name in the very next operation; the reactive store
  /// is only eventually consistent with a committed write, so under load it
  /// can throw `.earmarkNotFound` for an earmark that is already persisted.
  /// `fetchAll()` reflects the committed write immediately, making resolution
  /// deterministic.
  func resolveEarmark(named name: String, profileIdentifier: String) async throws -> Earmark {
    let earmarks = try await fetchEarmarks(profileIdentifier: profileIdentifier)
    return try Self.earmark(named: name, in: earmarks)
  }

  /// Authoritative earmark snapshot for a profile, read straight from the
  /// repository so it reflects every committed write immediately. Mirrors
  /// `fetchAccounts` — callers that resolve several names (e.g. `resolveLegs`)
  /// fetch once and match in-memory rather than re-reading per name.
  func fetchEarmarks(profileIdentifier: String) async throws -> [Earmark] {
    let session = try resolveSession(for: profileIdentifier)
    return try await session.backend.earmarks.fetchAll()
  }

  /// Case-insensitive name lookup within an already-fetched earmark list.
  static func earmark(named name: String, in earmarks: [Earmark]) throws -> Earmark {
    let lowered = name.lowercased()
    guard let earmark = earmarks.first(where: { $0.name.lowercased() == lowered }) else {
      throw AutomationError.earmarkNotFound(name)
    }
    return earmark
  }

  /// Creates a new earmark in the given profile.
  func createEarmark(
    profileIdentifier: String,
    name: String,
    targetAmount: Decimal? = nil,
    savingsEndDate: Date? = nil
  ) async throws -> Earmark {
    let session = try resolveSession(for: profileIdentifier)
    let instrument = session.profile.instrument
    let earmark = Earmark(
      id: UUID(),
      name: name,
      instrument: instrument,
      isHidden: false,
      position: session.earmarkStore.earmarks.count,
      savingsGoal: targetAmount.map { InstrumentAmount(quantity: $0, instrument: instrument) },
      savingsStartDate: savingsEndDate != nil ? Date() : nil,
      savingsEndDate: savingsEndDate
    )

    guard let created = await session.earmarkStore.create(earmark) else {
      throw AutomationError.operationFailed("Failed to create earmark")
    }
    return created
  }

  /// Updates an existing earmark.
  func updateEarmark(
    profileIdentifier: String,
    earmarkId: UUID,
    name: String? = nil,
    targetAmount: Decimal? = nil,
    savingsEndDate: Date? = nil
  ) async throws -> Earmark {
    let session = try resolveSession(for: profileIdentifier)
    let instrument = session.profile.instrument
    guard var earmark = session.earmarkStore.earmarks.by(id: earmarkId) else {
      throw AutomationError.earmarkNotFound(earmarkId.uuidString)
    }
    if let name { earmark.name = name }
    if let targetAmount {
      earmark.savingsGoal = InstrumentAmount(quantity: targetAmount, instrument: instrument)
    }
    if let savingsEndDate {
      earmark.savingsEndDate = savingsEndDate
      if earmark.savingsStartDate == nil {
        earmark.savingsStartDate = Date()
      }
    }

    guard let updated = await session.earmarkStore.update(earmark) else {
      throw AutomationError.operationFailed("Failed to update earmark")
    }
    return updated
  }

  /// Hides an earmark by UUID (earmarks cannot be deleted, only hidden).
  func deleteEarmark(profileIdentifier: String, earmarkId: UUID) async throws {
    let session = try resolveSession(for: profileIdentifier)
    guard var earmark = session.earmarkStore.earmarks.by(id: earmarkId) else {
      throw AutomationError.earmarkNotFound(earmarkId.uuidString)
    }
    earmark.isHidden = true
    guard await session.earmarkStore.update(earmark) != nil else {
      throw AutomationError.operationFailed("Failed to hide earmark")
    }
  }

  // MARK: - Category Operations

  /// Returns all categories for the given profile.
  func listCategories(profileIdentifier: String) throws -> [Category] {
    let session = try resolveSession(for: profileIdentifier)
    return session.categoryStore.categories.flattenedByPath().map(\.category)
  }

  /// Resolves a category by name or path (case-insensitive) within a profile.
  /// Matches either the category name or the full path (e.g., "Food:Groceries").
  ///
  /// Reads the authoritative repository snapshot (`fetchAll()`) rather than the
  /// reactive `CategoryStore.categories` — see
  /// `resolveAccount(named:profileIdentifier:)` for the read-after-write
  /// rationale. The repository returns a flat `[Category]`, so the hierarchy is
  /// rebuilt with `Categories(from:)` to keep full-path matching working.
  /// `fetchAll()` reflects the committed write immediately, making resolution
  /// deterministic.
  func resolveCategory(named name: String, profileIdentifier: String) async throws -> Category {
    let categories = try await fetchCategories(profileIdentifier: profileIdentifier)
    return try Self.category(named: name, in: categories)
  }

  /// Authoritative category hierarchy for a profile, rebuilt from the flat
  /// repository snapshot so it reflects every committed write immediately.
  /// Mirrors `fetchAccounts` — callers that resolve several names (e.g.
  /// `resolveLegs`) fetch once and match in-memory rather than re-reading
  /// per name.
  func fetchCategories(profileIdentifier: String) async throws -> Categories {
    let session = try resolveSession(for: profileIdentifier)
    return Categories(from: try await session.backend.categories.fetchAll())
  }

  /// Case-insensitive path-then-name lookup within an already-fetched
  /// category hierarchy.
  static func category(named name: String, in categories: Categories) throws -> Category {
    let lowered = name.lowercased()
    let entries = categories.flattenedByPath()

    // Try matching by path first, then by name
    if let entry = entries.first(where: { $0.path.lowercased() == lowered }) {
      return entry.category
    }
    if let entry = entries.first(where: { $0.category.name.lowercased() == lowered }) {
      return entry.category
    }

    throw AutomationError.categoryNotFound(name)
  }

  /// Creates a new category, optionally under a parent.
  func createCategory(
    profileIdentifier: String,
    name: String,
    parentName: String? = nil
  ) async throws -> Category {
    let parentId: UUID?
    if let parentName {
      parentId = try await resolveCategory(named: parentName, profileIdentifier: profileIdentifier)
        .id
    } else {
      parentId = nil
    }

    let session = try resolveSession(for: profileIdentifier)
    let category = Category(id: UUID(), name: name, parentId: parentId)

    guard let created = await session.categoryStore.create(category) else {
      throw AutomationError.operationFailed("Failed to create category")
    }
    return created
  }

  /// Deletes a category, optionally replacing it with another category.
  func deleteCategory(
    profileIdentifier: String,
    categoryId: UUID,
    replacementName: String? = nil
  ) async throws {
    let session = try resolveSession(for: profileIdentifier)

    let replacementId: UUID?
    if let replacementName {
      replacementId = try await resolveCategory(
        named: replacementName, profileIdentifier: profileIdentifier
      ).id
    } else {
      replacementId = nil
    }

    let success = await session.categoryStore.delete(id: categoryId, withReplacement: replacementId)
    if !success {
      throw AutomationError.operationFailed("Failed to delete category")
    }
  }

  // MARK: - Investment Operations

  /// Sets the investment value for an account on a given date.
  func setInvestmentValue(
    profileIdentifier: String,
    accountName: String,
    date: Date,
    value: Decimal
  ) async throws {
    let session = try resolveSession(for: profileIdentifier)
    let account = try await resolveAccount(
      named: accountName, profileIdentifier: profileIdentifier)

    guard account.type == .investment else {
      throw AutomationError.invalidParameter(
        "Account '\(accountName)' is not an investment account")
    }

    let instrument = session.profile.instrument
    let amount = InstrumentAmount(quantity: value, instrument: instrument)
    await session.investmentStore.setValue(accountId: account.id, date: date, value: amount)
  }

  /// Returns positions for a given investment account.
  func getPositions(profileIdentifier: String, accountName: String) async throws -> [Position] {
    let session = try resolveSession(for: profileIdentifier)
    let account = try await resolveAccount(
      named: accountName, profileIdentifier: profileIdentifier)
    await session.investmentStore.loadPositions(accountId: account.id)
    return session.investmentStore.positions
  }

  // MARK: - Analysis Operations

  /// Loads analysis data (daily balances, expense breakdown, income/expense).
  func loadAnalysis(
    profileIdentifier: String,
    historyMonths: Int? = nil,
    forecastMonths: Int? = nil
  ) async throws -> AnalysisData {
    let session = try resolveSession(for: profileIdentifier)

    if let historyMonths {
      session.analysisStore.historyMonths = historyMonths
    }
    if let forecastMonths {
      session.analysisStore.forecastMonths = forecastMonths
    }

    await session.analysisStore.loadAll()

    if let error = session.analysisStore.error {
      throw AutomationError.operationFailed(
        "Failed to load analysis: \(error.localizedDescription)")
    }

    return AnalysisData(
      dailyBalances: session.analysisStore.dailyBalances,
      expenseBreakdown: session.analysisStore.expenseBreakdown,
      incomeAndExpense: session.analysisStore.incomeAndExpense
    )
  }

  // MARK: - Refresh

  /// Refreshes all stores for the given profile concurrently.
  /// `AccountStore`, `EarmarkStore`, and `CategoryStore` are all
  /// reactive — they self-load via `observeAll()` from `init`, so this
  /// method has no work to dispatch beyond resolving the session
  /// (which validates the identifier). Part of the AutomationService
  /// surface for scripts that call `refresh` defensively before
  /// reading store state.
  func refresh(profileIdentifier: String) async throws {
    _ = try resolveSession(for: profileIdentifier)
  }

  // MARK: - Crypto sync

  /// Forces a sync of every crypto account in the given profile, bypassing
  /// the staleness check. Used by automation / smoke tests to drive the
  /// importer end-to-end without waiting for the hourly stale timer or
  /// scenePhase `.active` trigger. Throws when the profile cannot be
  /// resolved or when the crypto-sync store is unavailable (degraded
  /// launches without an instrument registry).
  func syncCryptoAccounts(profileIdentifier: String) async throws {
    let session = try resolveSession(for: profileIdentifier)
    guard let cryptoSyncStore = session.cryptoSyncStore else {
      throw AutomationError.operationFailed(
        "Crypto sync is not available for this profile (instrument registry not configured).")
    }
    // Every synced account, not just `.crypto`: exchange accounts are
    // claimed by their own sync source (e.g. `CoinstashSyncSource`) and
    // must sync here too, mirroring the store's source-based stale-timer
    // selection. The store still asks each source `handles(_:)`, so
    // passing a non-syncable account is a harmless no-op.
    let syncedAccounts = session.accountStore.accounts.filter { $0.type.isSynced }
    guard !syncedAccounts.isEmpty else { return }
    await cryptoSyncStore.syncAccounts(syncedAccounts)
  }
}
