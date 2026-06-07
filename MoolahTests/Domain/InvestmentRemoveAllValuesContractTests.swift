import Foundation
import Testing

@testable import Moolah

@Suite("InvestmentRepository Remove All Values Contract")
struct InvestmentRemoveAllValuesContractTests {

  private func makeDate(year: Int, month: Int, day: Int) throws -> Date {
    try makeContractTestDate(year: year, month: month, day: day)
  }

  /// Reads back every recorded value for an account by paging through
  /// `fetchValues`, so a test can assert the table is empty afterwards.
  private func allValues(
    _ repo: any InvestmentRepository, accountId: UUID
  ) async throws -> [InvestmentValue] {
    try await repo.fetchValues(accountId: accountId, page: 0, pageSize: 1000).values
  }

  @Test("removeAllValues deletes every value for the account and leaves others untouched")
  func testRemoveAllValues() async throws {
    let accountA = UUID()
    let accountB = UUID()
    let instrument = Instrument.defaultTestInstrument
    let amount = InstrumentAmount(quantity: Decimal(1000), instrument: instrument)

    let repo = try makeCloudKitInvestmentRepository()

    // Three values on A across distinct dates, two on B.
    try await repo.setValue(
      accountId: accountA, date: try makeDate(year: 2024, month: 1, day: 1), value: amount)
    try await repo.setValue(
      accountId: accountA, date: try makeDate(year: 2024, month: 2, day: 1), value: amount)
    try await repo.setValue(
      accountId: accountA, date: try makeDate(year: 2024, month: 3, day: 1), value: amount)
    try await repo.setValue(
      accountId: accountB, date: try makeDate(year: 2024, month: 1, day: 1), value: amount)
    try await repo.setValue(
      accountId: accountB, date: try makeDate(year: 2024, month: 2, day: 1), value: amount)

    let deletedCount = try await repo.removeAllValues(accountId: accountA)
    #expect(deletedCount == 3)

    let remainingA = try await allValues(repo, accountId: accountA)
    #expect(remainingA.isEmpty)

    let remainingB = try await allValues(repo, accountId: accountB)
    #expect(remainingB.count == 2)
  }

  @Test("removeAllValues on an account with no values returns zero")
  func testRemoveAllValuesEmpty() async throws {
    let repo = try makeCloudKitInvestmentRepository()
    let deletedCount = try await repo.removeAllValues(accountId: UUID())
    #expect(deletedCount == 0)
  }
}
