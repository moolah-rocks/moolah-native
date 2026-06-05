import Foundation
import Testing

@testable import Moolah

@Suite("AutomationService Account Operations")
@MainActor
struct AutomationServiceAccountTests {
  private struct OpenSessionFailed: Error {}

  private func makeServiceWithSession() async throws -> (AutomationService, ProfileSession) {
    let containerManager = try ProfileContainerManager.forTesting()
    let sessionManager = SessionManager(
      containerManager: containerManager,
      profileIndexRepository: containerManager.profileIndexRepositoryForTesting)
    let profile = Profile(
      label: "Test",
      currencyCode: "AUD",
      financialYearStartMonth: 7
    )
    guard case .ready(let session) = await sessionManager.session(for: profile) else {
      Issue.record("expected .ready")
      throw OpenSessionFailed()
    }
    // AccountStore is reactive — wait for the first emission so any
    // pre-seeded accounts are visible. For a fresh test session there
    // are none, but the wait keeps the public API consistent.
    try await session.accountStore.waitForFirstEmission()
    let service = AutomationService(sessionManager: sessionManager)
    return (service, session)
  }

  @Test("createAccount creates and lists accounts")
  func createAndListAccounts() async throws {
    let (service, session) = try await makeServiceWithSession()

    let account = try await service.createAccount(
      profileIdentifier: "Test",
      name: "Savings",
      type: .bank
    )

    #expect(account.name == "Savings")
    #expect(account.type == .bank)
    #expect(account.positions.isEmpty)

    // AccountStore is reactive — the new account is observable via
    // `accounts` once `observeAll()` delivers the post-write snapshot.
    try await session.accountStore.waitForNextEmission(
      matching: { $0.accounts.count == 1 },
      description: "new account observable"
    )

    let accounts = try service.listAccounts(profileIdentifier: "Test")
    #expect(accounts.count == 1)
    #expect(accounts.first?.name == "Savings")
  }

  @Test("resolveAccount finds account by name case-insensitively")
  func resolveAccountByNameCaseInsensitive() async throws {
    let (service, _) = try await makeServiceWithSession()
    _ = try await service.createAccount(
      profileIdentifier: "Test",
      name: "My Savings",
      type: .bank
    )

    // `resolveAccount` reads the authoritative repository snapshot, so it
    // sees the committed account without waiting on the reactive store.
    let resolved = try await service.resolveAccount(
      named: "my savings", profileIdentifier: "Test")
    #expect(resolved.name == "My Savings")
  }

  @Test("resolveAccount throws when not found")
  func resolveAccountNotFoundThrows() async throws {
    let (service, _) = try await makeServiceWithSession()

    await #expect(throws: AutomationError.self) {
      try await service.resolveAccount(named: "NonExistent", profileIdentifier: "Test")
    }
  }

  @Test("resolveAccount finds account by UUID")
  func resolveAccountByUUID() async throws {
    let (service, _) = try await makeServiceWithSession()
    let created = try await service.createAccount(
      profileIdentifier: "Test",
      name: "Checking",
      type: .bank
    )

    // Authoritative repository read — no need to wait on the reactive store.
    let resolved = try await service.resolveAccount(id: created.id, profileIdentifier: "Test")
    #expect(resolved.name == "Checking")
  }

  @Test("getNetWorth returns sum of current and investment accounts")
  func getNetWorth() async throws {
    let (service, session) = try await makeServiceWithSession()
    let instrument = session.profile.instrument

    // Create a bank account with a balance
    let bankAccount = Account(
      name: "Bank",
      type: .bank,
      instrument: instrument,
      position: 0
    )
    let openingBalance = InstrumentAmount(quantity: 1000, instrument: instrument)
    _ = try await session.accountStore.create(bankAccount, openingBalance: openingBalance)

    // Wait for the reactive observation to deliver the position
    // computed from the opening-balance transaction.
    try await session.accountStore.waitForNextEmission(
      matching: { !($0.positions(for: bankAccount.id).isEmpty) },
      description: "opening balance position observable"
    )

    let netWorth = try await service.getNetWorth(profileIdentifier: "Test")
    #expect(netWorth.quantity == 1000)
  }

  @Test("updateAccount changes account name")
  func updateAccountName() async throws {
    let (service, session) = try await makeServiceWithSession()
    let created = try await service.createAccount(
      profileIdentifier: "Test",
      name: "Old Name",
      type: .bank
    )

    try await session.accountStore.waitForNextEmission(
      matching: { $0.accounts.by(id: created.id) != nil },
      description: "new account observable"
    )

    let updated = try await service.updateAccount(
      profileIdentifier: "Test",
      accountId: created.id,
      changes: AccountChanges(name: "New Name")
    )

    #expect(updated.name == "New Name")
  }

  @Test("deleteAccount soft-deletes (hides) the account")
  func deleteAccount() async throws {
    let (service, session) = try await makeServiceWithSession()
    let created = try await service.createAccount(
      profileIdentifier: "Test",
      name: "ToDelete",
      type: .bank
    )

    try await session.accountStore.waitForNextEmission(
      matching: { $0.accounts.by(id: created.id) != nil },
      description: "new account observable"
    )

    try await service.deleteAccount(profileIdentifier: "Test", accountId: created.id)

    // `AccountRepository.delete` is a soft delete (flips `isHidden`).
    // Under the reactive observation contract, the row stays in GRDB
    // (and therefore in `accounts`) but with `isHidden == true`.
    try await session.accountStore.waitForNextEmission(
      matching: { $0.accounts.by(id: created.id)?.isHidden == true },
      description: "account hidden observable"
    )

    // `listAccounts` exposes the raw `accounts` list (including hidden
    // rows), so the assertion checks the soft-delete contract: the row
    // is still present but hidden.
    let accounts = try service.listAccounts(profileIdentifier: "Test")
    #expect(accounts.count == 1)
    #expect(accounts.first?.isHidden == true)
  }
}
