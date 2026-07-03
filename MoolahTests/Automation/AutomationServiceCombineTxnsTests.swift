import Foundation
import Testing

@testable import Moolah

@Suite("AutomationService Combine Transactions")
@MainActor
struct AutomationServiceCombineTxnsTests {
  private struct OpenSessionFailed: Error {}

  private func makeServiceWithSession() async throws -> (AutomationService, ProfileSession) {
    let containerManager = try ProfileContainerManager.forTesting()
    let sessionManager = SessionManager(
      containerManager: containerManager,
      profileIndexRepository: containerManager.profileIndexRepositoryForTesting)
    let profile = Profile(label: "Test", currencyCode: "AUD", financialYearStartMonth: 7)
    guard case .ready(let session) = await sessionManager.session(for: profile) else {
      Issue.record("expected .ready")
      throw OpenSessionFailed()
    }
    try await session.accountStore.waitForFirstEmission()
    return (AutomationService(sessionManager: sessionManager), session)
  }

  private func makeSingleLeg(
    session: ProfileSession,
    accountId: UUID,
    quantity: Decimal,
    payee: String,
    on date: Date
  ) async throws -> Transaction {
    let transaction = Transaction(
      id: UUID(), date: date, payee: payee,
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: session.profile.instrument,
          quantity: quantity, type: quantity < 0 ? .expense : .income)
      ])
    return try await session.backend.transactions.create(transaction)
  }

  @Test("combines three same-day same-payee transactions into one")
  func combinesThree() async throws {
    let (service, session) = try await makeServiceWithSession()
    let account = try await service.createAccount(
      profileIdentifier: "Test", name: "Checking", type: .bank)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    _ = try await makeSingleLeg(
      session: session, accountId: account.id, quantity: -10, payee: "Acme", on: date)
    _ = try await makeSingleLeg(
      session: session, accountId: account.id, quantity: -20, payee: "Acme", on: date)
    _ = try await makeSingleLeg(
      session: session, accountId: account.id, quantity: -30, payee: "Acme", on: date)
    let all = try await session.backend.transactions.fetchAll(filter: TransactionFilter())
    let ids = all.map(\.id)

    let merged = try await service.combineTransactions(profileIdentifier: "Test", ids: ids)

    #expect(merged.legs.count == 3)
    let after = try await session.backend.transactions.fetchAll(filter: TransactionFilter())
    #expect(after.count == 1)
  }

  @Test("throws on an invalid (different-payee) selection without mutating")
  func throwsOnInvalid() async throws {
    let (service, session) = try await makeServiceWithSession()
    let account = try await service.createAccount(
      profileIdentifier: "Test", name: "Checking", type: .bank)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let txA = try await makeSingleLeg(
      session: session, accountId: account.id, quantity: -10, payee: "Acme", on: date)
    let txB = try await makeSingleLeg(
      session: session, accountId: account.id, quantity: -20, payee: "Other", on: date)

    await #expect(throws: (any Error).self) {
      _ = try await service.combineTransactions(
        profileIdentifier: "Test", ids: [txA.id, txB.id])
    }
    let after = try await session.backend.transactions.fetchAll(filter: TransactionFilter())
    #expect(after.count == 2)
  }
}
