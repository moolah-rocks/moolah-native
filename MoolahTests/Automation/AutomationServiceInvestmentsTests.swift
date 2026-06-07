import Foundation
import Testing

@testable import Moolah

@Suite("AutomationService Investments")
@MainActor
struct AutomationServiceInvestmentsTests {

  @Test("clearInvestmentValues deletes every value for the account and returns the count")
  func clearsAllValues() async throws {
    let (service, session) = try await AutomationTestSession.make()
    let account = try await service.createAccount(
      profileIdentifier: "Test", name: "Brokerage", type: .investment)

    let amount = InstrumentAmount(quantity: Decimal(5000), instrument: session.profile.instrument)
    let first = try #require(
      Calendar.current.date(from: DateComponents(year: 2024, month: 1, day: 1)))
    let second = try #require(
      Calendar.current.date(from: DateComponents(year: 2024, month: 2, day: 1)))
    try await session.backend.investments.setValue(
      accountId: account.id, date: first, value: amount)
    try await session.backend.investments.setValue(
      accountId: account.id, date: second, value: amount)

    let deletedCount = try await service.clearInvestmentValues(
      profileIdentifier: "Test", accountName: "Brokerage")
    #expect(deletedCount == 2)

    let page = try await session.backend.investments.fetchValues(
      accountId: account.id, page: 0, pageSize: 1000)
    #expect(page.values.isEmpty)
  }

  @Test("clearInvestmentValues throws for an unknown account name")
  func throwsForUnknownAccount() async throws {
    let (service, _) = try await AutomationTestSession.make()
    await #expect(throws: AutomationError.self) {
      _ = try await service.clearInvestmentValues(
        profileIdentifier: "Test", accountName: "Does Not Exist")
    }
  }
}
