import Foundation
import Testing

@testable import Moolah

/// Regression guard for the documented snapshot-write policy: the
/// AutomationService `setInvestmentValue` (the entry point invoked by
/// `AddInvestmentValueIntent`) writes the snapshot regardless of the
/// account's current `valuationMode`. A user in
/// `.calculatedFromTrades` mode can still record a manual value
/// (e.g. for a one-off audit) without first flipping the mode.
@Suite("AddInvestmentValueIntent (policy)")
@MainActor
struct AddInvestmentValueIntentPolicyTests {
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
    try await session.accountStore.waitForFirstEmission()
    let service = AutomationService(sessionManager: sessionManager)
    return (service, session)
  }

  @Test("writes a snapshot even when account is in calculatedFromTrades mode")
  func writesInTradesMode() async throws {
    let (service, session) = try await makeServiceWithSession()

    // `store.create` promotes every new investment account to
    // `.calculatedFromTrades`, so this matches the production
    // "user creates a brokerage today" path.
    let saved = try await session.accountStore.create(
      Account(name: "Brokerage", type: .investment, instrument: session.profile.instrument))
    #expect(saved.valuationMode == .calculatedFromTrades)
    try await session.accountStore.waitForNextEmission(
      matching: { $0.accounts.contains { $0.name == "Brokerage" } },
      description: "new account observable"
    )

    let date = Date(timeIntervalSince1970: 1_700_000_000)
    try await service.setInvestmentValue(
      profileIdentifier: "Test",
      accountName: "Brokerage",
      date: date,
      value: 100)

    let page = try await session.backend.investments.fetchValues(
      accountId: saved.id, page: 0, pageSize: 10)
    #expect(page.values.count == 1)
    #expect(page.values.first?.value.quantity == 100)
  }
}
