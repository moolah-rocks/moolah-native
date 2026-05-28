import Foundation
import Testing

@testable import Moolah

@Suite("AutomationService Transaction Operations")
@MainActor
struct AutomationServiceTransactionTests {
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
    // AccountStore, EarmarkStore, and CategoryStore are all reactive
    // — wait for the first emission so any pre-seeded rows are visible.
    try await session.accountStore.waitForFirstEmission()
    try await session.earmarkStore.waitForFirstEmission()
    try await session.categoryStore.waitForFirstEmission()
    let service = AutomationService(sessionManager: sessionManager)
    return (service, session)
  }

  @Test("createTransaction creates a single-leg transaction")
  func createSingleLegTransaction() async throws {
    let (service, session) = try await makeServiceWithSession()

    // Create an account first
    _ = try await service.createAccount(
      profileIdentifier: "Test",
      name: "Checking",
      type: .bank
    )
    try await session.accountStore.waitForNextEmission(
      matching: { $0.accounts.contains { $0.name == "Checking" } },
      description: "new account observable"
    )

    let transaction = try await service.createTransaction(
      profileIdentifier: "Test",
      payee: "Grocery Store",
      date: Date(),
      legs: [
        AutomationService.LegSpec(
          accountName: "Checking",
          amount: -50,
          categoryName: nil,
          earmarkName: nil
        )
      ],
      notes: "Weekly shopping"
    )

    #expect(transaction.payee == "Grocery Store")
    #expect(transaction.notes == "Weekly shopping")
    #expect(transaction.legs.count == 1)
    #expect(transaction.legs.first?.quantity == -50)
    #expect(transaction.legs.first?.type == .expense)
  }

  @Test("listTransactions returns created transactions")
  func listTransactions() async throws {
    let (service, session) = try await makeServiceWithSession()

    _ = try await service.createAccount(
      profileIdentifier: "Test",
      name: "Checking",
      type: .bank
    )
    try await session.accountStore.waitForNextEmission(
      matching: { $0.accounts.contains { $0.name == "Checking" } },
      description: "new account observable"
    )

    _ = try await service.createTransaction(
      profileIdentifier: "Test",
      payee: "Store A",
      date: Date(),
      legs: [
        AutomationService.LegSpec(
          accountName: "Checking",
          amount: -25,
          categoryName: nil,
          earmarkName: nil
        )
      ]
    )

    let transactions = try await service.listTransactions(profileIdentifier: "Test")
    #expect(transactions.count == 1)
    #expect(transactions.first?.payee == "Store A")
  }

  @Test("createTransaction with positive amount creates income")
  func createIncomeTransaction() async throws {
    let (service, session) = try await makeServiceWithSession()

    _ = try await service.createAccount(
      profileIdentifier: "Test",
      name: "Checking",
      type: .bank
    )
    try await session.accountStore.waitForNextEmission(
      matching: { $0.accounts.contains { $0.name == "Checking" } },
      description: "new account observable"
    )

    let transaction = try await service.createTransaction(
      profileIdentifier: "Test",
      payee: "Employer",
      date: Date(),
      legs: [
        AutomationService.LegSpec(
          accountName: "Checking",
          amount: 3000,
          categoryName: nil,
          earmarkName: nil
        )
      ]
    )

    #expect(transaction.legs.first?.type == .income)
    #expect(transaction.legs.first?.quantity == 3000)
  }
}
