import Foundation
import Testing

@testable import Moolah

@Suite("AutomationService Legs — remove")
@MainActor
struct AutomationServiceRemoveLegTests {

  @Test("removeLeg drops the leg from a multi-leg transaction")
  func removeLegDropsLeg() async throws {
    let (service, session) = try await AutomationTestSession.make()
    let checking = try await service.createAccount(
      profileIdentifier: "Test", name: "Checking", type: .bank)
    let savings = try await service.createAccount(
      profileIdentifier: "Test", name: "Savings", type: .bank)

    let txn = try await LegTestSupport.makeSingleLeg(
      session: session, accountId: checking.id, quantity: -100, payee: "Move")
    let withSecond = try await service.addLeg(
      profileIdentifier: "Test",
      transactionId: txn.id,
      draft: AutomationService.LegDraft(
        accountName: "Savings", amount: 100, type: "transfer"))
    let removableId = try #require(withSecond.legs.first { $0.accountId == savings.id }).id

    let updated = try await service.removeLeg(profileIdentifier: "Test", legId: removableId)

    #expect(updated.legs.count == 1)
    #expect(!updated.legs.contains { $0.id == removableId })

    let persisted = try await LegTestSupport.fetchById(session, txn.id)
    #expect(persisted.legs.count == 1)
  }

  @Test("removeLeg throws when it would leave the transaction with no legs")
  func removeLastLegThrows() async throws {
    let (service, session) = try await AutomationTestSession.make()
    let bank = try await service.createAccount(
      profileIdentifier: "Test", name: "Bank", type: .bank)
    let txn = try await LegTestSupport.makeSingleLeg(
      session: session, accountId: bank.id, quantity: -100, payee: "Only")
    let legId = try #require(txn.legs.first).id

    await #expect(throws: AutomationError.self) {
      _ = try await service.removeLeg(profileIdentifier: "Test", legId: legId)
    }

    // The transaction is untouched.
    let persisted = try await LegTestSupport.fetchById(session, txn.id)
    #expect(persisted.legs.count == 1)
  }

  @Test("removeLeg throws for a missing leg id")
  func removeLegMissingThrows() async throws {
    let (service, _) = try await AutomationTestSession.make()
    _ = try await service.createAccount(
      profileIdentifier: "Test", name: "Bank", type: .bank)

    await #expect(throws: AutomationError.self) {
      _ = try await service.removeLeg(profileIdentifier: "Test", legId: UUID())
    }
  }
}
