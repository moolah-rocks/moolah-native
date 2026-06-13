import Foundation
import Testing

@testable import Moolah

@Suite("AutomationService Account Operations")
@MainActor
struct AutomationServiceAccountTests {

  @Test("createAccount creates and lists accounts")
  func createAndListAccounts() async throws {
    let (service, _) = try await AutomationTestSession.make()

    let account = try await service.createAccount(
      profileIdentifier: "Test",
      name: "Savings",
      type: .bank
    )

    #expect(account.name == "Savings")
    #expect(account.type == .bank)
    #expect(account.positions.isEmpty)

    // AccountStore is reactive — the new account becomes listable shortly
    // after the GRDB write commits. Poll the exact asserted value so a racing
    // observation pass can't slip a stale read between an awaited emission and
    // a single read.
    await expectEventually("created account is listed via the service") {
      let accounts = (try? service.listAccounts(profileIdentifier: "Test")) ?? []
      return accounts.count == 1 && accounts.first?.name == "Savings"
    }
  }

  @Test("createAccount defaults a new investment account to calculatedFromTrades")
  func createInvestmentDefaultsToCalculated() async throws {
    let (service, _) = try await AutomationTestSession.make()

    // The migration reconstructs non-synced venues as manual investment
    // accounts that must value from positions, not a recorded mark. A scripted
    // `create account type "investment"` must therefore land in
    // `.calculatedFromTrades` — `AccountStore.create` promotes the default
    // `.recordedValue` for investment accounts, so no recordedValue account is
    // creatable through this path.
    let account = try await service.createAccount(
      profileIdentifier: "Test",
      name: "Manual Crypto",
      type: .investment
    )

    #expect(account.valuationMode == .calculatedFromTrades)
  }

  @Test("resolveAccount finds account by name case-insensitively")
  func resolveAccountByNameCaseInsensitive() async throws {
    let (service, _) = try await AutomationTestSession.make()
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
    let (service, _) = try await AutomationTestSession.make()

    await #expect(throws: AutomationError.self) {
      try await service.resolveAccount(named: "NonExistent", profileIdentifier: "Test")
    }
  }

  @Test("resolveAccount finds account by UUID")
  func resolveAccountByUUID() async throws {
    let (service, _) = try await AutomationTestSession.make()
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
    let (service, session) = try await AutomationTestSession.make()
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

    // The net worth derives from the position computed off the opening-balance
    // transaction, which the reactive observation delivers shortly after the
    // write commits. Poll the exact asserted value so a racing observation pass
    // can't slip a stale read in.
    await expectEventually("net worth reflects the opening balance") {
      (try? await service.getNetWorth(profileIdentifier: "Test"))?.quantity == 1000
    }
  }

  @Test("updateAccount changes account name")
  func updateAccountName() async throws {
    let (service, session) = try await AutomationTestSession.make()
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
    let (service, session) = try await AutomationTestSession.make()
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
    // `listAccounts` exposes the raw `accounts` list (including hidden rows),
    // so polling it asserts the soft-delete contract: the row is still present
    // but hidden. Poll the exact asserted value so a racing observation pass
    // can't slip a stale read between an awaited emission and a single read.
    await expectEventually("deleted account is hidden but still listed") {
      let accounts = (try? service.listAccounts(profileIdentifier: "Test")) ?? []
      return accounts.count == 1 && accounts.first?.isHidden == true
    }
  }
}
