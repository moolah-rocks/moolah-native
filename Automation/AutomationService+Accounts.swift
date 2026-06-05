import Foundation

// Account operations for `AutomationService`: listing, authoritative
// resolution (by name / id), net worth, and create / update / delete.
// All members are `@MainActor` via the containing class.
extension AutomationService {

  // MARK: - Account Operations

  /// Returns all accounts for the given profile.
  func listAccounts(profileIdentifier: String) throws -> [Account] {
    let session = try resolveSession(for: profileIdentifier)
    return Array(session.accountStore.accounts)
  }

  /// Resolves an account by name (case-insensitive) within a profile.
  ///
  /// Reads the authoritative repository snapshot (`fetchAll()`) rather
  /// than the reactive `AccountStore.accounts`. Automation is a scripted,
  /// read-after-write context — a script (or a single intent) creates an
  /// account and then references it by name in the very next operation.
  /// The reactive store is only *eventually* consistent with a committed
  /// write: under load `observeAll()` can deliver the new snapshot after
  /// the reference reads it, so a reactive-store lookup can throw
  /// `.accountNotFound` for an account that is already persisted.
  /// `fetchAll()` reflects the committed write immediately, making
  /// resolution deterministic.
  func resolveAccount(named name: String, profileIdentifier: String) async throws -> Account {
    let accounts = try await fetchAccounts(profileIdentifier: profileIdentifier)
    return try Self.account(named: name, in: accounts)
  }

  /// Resolves an account by UUID within a profile. Authoritative read —
  /// see `resolveAccount(named:profileIdentifier:)` for the rationale.
  func resolveAccount(id: UUID, profileIdentifier: String) async throws -> Account {
    let accounts = try await fetchAccounts(profileIdentifier: profileIdentifier)
    guard let account = accounts.first(where: { $0.id == id }) else {
      throw AutomationError.accountNotFound(id.uuidString)
    }
    return account
  }

  /// Authoritative account snapshot for a profile, read straight from the
  /// repository so it reflects every committed write immediately.
  func fetchAccounts(profileIdentifier: String) async throws -> [Account] {
    let session = try resolveSession(for: profileIdentifier)
    return try await session.backend.accounts.fetchAll()
  }

  /// Case-insensitive name lookup within an already-fetched account list.
  /// Shared by `resolveAccount(named:)` and `resolveLegs` (which fetches
  /// the snapshot once and resolves every leg against it).
  static func account(named name: String, in accounts: [Account]) throws -> Account {
    let lowered = name.lowercased()
    guard let account = accounts.first(where: { $0.name.lowercased() == lowered }) else {
      throw AutomationError.accountNotFound(name)
    }
    return account
  }

  /// Returns the net worth (current + investment totals) for the given profile,
  /// converted into the profile's instrument.
  func getNetWorth(profileIdentifier: String) async throws -> InstrumentAmount {
    let session = try resolveSession(for: profileIdentifier)
    do {
      return try await session.accountStore.computeConvertedNetWorth(
        in: session.profile.instrument)
    } catch {
      throw AutomationError.operationFailed(
        "Failed to compute net worth: \(error.localizedDescription)")
    }
  }

  /// Creates a new account in the given profile.
  func createAccount(
    profileIdentifier: String,
    name: String,
    type: AccountType,
    isHidden: Bool = false
  ) async throws -> Account {
    let session = try resolveSession(for: profileIdentifier)
    let instrument = session.profile.instrument
    let account = Account(
      id: UUID(),
      name: name,
      type: type,
      instrument: instrument,
      position: session.accountStore.accounts.count,
      isHidden: isHidden
    )
    do {
      return try await session.accountStore.create(account)
    } catch {
      throw AutomationError.operationFailed(
        "Failed to create account: \(error.localizedDescription)")
    }
  }

  /// Updates an existing account's name and/or hidden status.
  func updateAccount(
    profileIdentifier: String,
    accountId: UUID,
    changes: AccountChanges
  ) async throws -> Account {
    let session = try resolveSession(for: profileIdentifier)
    guard var account = session.accountStore.accounts.by(id: accountId) else {
      throw AutomationError.accountNotFound(accountId.uuidString)
    }
    if let name = changes.name { account.name = name }
    if case .setTo(let hidden) = changes.hidden { account.isHidden = hidden }
    do {
      return try await session.accountStore.update(account)
    } catch {
      throw AutomationError.operationFailed(
        "Failed to update account: \(error.localizedDescription)")
    }
  }

  /// Deletes an account by UUID.
  func deleteAccount(profileIdentifier: String, accountId: UUID) async throws {
    let session = try resolveSession(for: profileIdentifier)
    do {
      try await session.accountStore.delete(id: accountId)
    } catch {
      throw AutomationError.operationFailed(
        "Failed to delete account: \(error.localizedDescription)")
    }
  }
}
