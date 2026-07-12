import Foundation
import Testing

@testable import Moolah

@Suite("AutomationService Investments")
@MainActor
struct AutomationServiceInvestmentsTests {

  @Test("getPositions returns transaction-derived account positions")
  func getsTransactionDerivedPositions() async throws {
    let (service, session) = try await AutomationTestSession.make()
    let account = try await service.createAccount(
      profileIdentifier: "Test", name: "Brokerage", type: .investment)
    let stock = Instrument.stock(ticker: "MOO", exchange: "ASX", name: "Moolah")
    _ = try await session.backend.transactions.create(
      Transaction(
        date: Date(),
        payee: "Buy",
        legs: [
          TransactionLeg(
            accountId: account.id,
            instrument: stock,
            quantity: 12,
            type: .transfer)
        ]))

    let positions = try await service.getPositions(
      profileIdentifier: "Test", accountName: "Brokerage")

    #expect(positions == [Position(instrument: stock, quantity: 12)])
  }
}
