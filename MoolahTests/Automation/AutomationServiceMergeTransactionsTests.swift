import Foundation
import Testing

@testable import Moolah

@Suite("AutomationService Merge Transactions")
@MainActor
struct AutomationServiceMergeTransactionsTests {
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

  /// Persists a single-leg transaction directly through the repository so the
  /// leg's `externalId` can be set (the create-transaction service surface
  /// does not expose it). The leg sits in the profile's instrument; its
  /// `.income` / `.expense` type follows the quantity's sign.
  private func makeSingleLeg(
    session: ProfileSession,
    accountId: UUID,
    quantity: Decimal,
    payee: String,
    externalId: String? = nil
  ) async throws -> Transaction {
    let transaction = Transaction(
      id: UUID(),
      date: Date(),
      payee: payee,
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: session.profile.instrument,
          quantity: quantity,
          externalId: externalId,
          type: quantity < 0 ? .expense : .income)
      ])
    return try await session.backend.transactions.create(transaction)
  }

  @Test("merges two opposite-equal single-account transactions into one transfer")
  func mergesIntoTransfer() async throws {
    let (service, session) = try await makeServiceWithSession()
    let checking = try await service.createAccount(
      profileIdentifier: "Test", name: "Checking", type: .bank)
    let savings = try await service.createAccount(
      profileIdentifier: "Test", name: "Savings", type: .bank)

    let outgoing = try await makeSingleLeg(
      session: session, accountId: checking.id, quantity: -100, payee: "Transfer out")
    let incoming = try await makeSingleLeg(
      session: session, accountId: savings.id, quantity: 100, payee: "Transfer in")

    let merged = try await service.mergeTransactions(
      profileIdentifier: "Test", firstId: outgoing.id, secondId: incoming.id)

    let transferLegs = merged.legs.filter { $0.type == .transfer }
    #expect(transferLegs.count == 2)
    #expect(Set(transferLegs.compactMap(\.accountId)) == [checking.id, savings.id])
    #expect(Set(transferLegs.map(\.quantity)) == [-100, 100])

    // Both source transactions are gone.
    let remaining = try await session.backend.transactions.fetchAll(filter: TransactionFilter())
    let remainingIds = Set(remaining.map(\.id))
    #expect(!remainingIds.contains(outgoing.id))
    #expect(!remainingIds.contains(incoming.id))
    #expect(remainingIds.contains(merged.id))
  }

  @Test("preserves a source leg's externalId on the merged transfer leg")
  func preservesExternalId() async throws {
    let (service, session) = try await makeServiceWithSession()
    let bank = try await service.createAccount(
      profileIdentifier: "Test", name: "Bank", type: .bank)
    let exchange = try await service.createAccount(
      profileIdentifier: "Test", name: "Exchange", type: .exchange)

    let bankLeg = try await makeSingleLeg(
      session: session, accountId: bank.id, quantity: -250, payee: "Bank transfer")
    let syncedLeg = try await makeSingleLeg(
      session: session, accountId: exchange.id, quantity: 250, payee: "Exchange deposit",
      externalId: "chain-tx-hash-abc")

    let merged = try await service.mergeTransactions(
      profileIdentifier: "Test", firstId: bankLeg.id, secondId: syncedLeg.id)

    let preserved = merged.legs.first { $0.externalId == "chain-tx-hash-abc" }
    #expect(preserved != nil)
    #expect(preserved?.type == .transfer)
    #expect(preserved?.accountId == exchange.id)
  }

  @Test("throws when both transactions sit on the same account")
  func sameAccountThrows() async throws {
    let (service, session) = try await makeServiceWithSession()
    let checking = try await service.createAccount(
      profileIdentifier: "Test", name: "Checking", type: .bank)

    let first = try await makeSingleLeg(
      session: session, accountId: checking.id, quantity: -100, payee: "A")
    let second = try await makeSingleLeg(
      session: session, accountId: checking.id, quantity: 100, payee: "B")

    await #expect(throws: AutomationError.self) {
      _ = try await service.mergeTransactions(
        profileIdentifier: "Test", firstId: first.id, secondId: second.id)
    }
  }

  @Test("throws when a transaction id does not exist")
  func missingTransactionThrows() async throws {
    let (service, session) = try await makeServiceWithSession()
    let checking = try await service.createAccount(
      profileIdentifier: "Test", name: "Checking", type: .bank)

    let existing = try await makeSingleLeg(
      session: session, accountId: checking.id, quantity: -100, payee: "A")

    await #expect(throws: AutomationError.self) {
      _ = try await service.mergeTransactions(
        profileIdentifier: "Test", firstId: existing.id, secondId: UUID())
    }
  }
}
