import Foundation
import Testing

@testable import Moolah

/// Aggregation-layer integration tests pinning that
/// `fetchDailyBalancesAggregation` populates the investment position fields
/// from `readDailyBalancesAggregation`. The fold-contract tests in
/// `DailyBalanceInvestmentPositionTests` exercise the new fold by
/// constructing `DailyBalancesAggregation` directly; these tests
/// pin the SQL-to-struct wiring so a regression in the aggregation
/// builder doesn't ship past every fold-contract assertion.
@Suite("GRDBAnalysisRepository fetchDailyBalancesAggregation — investment position fields")
struct GRDBDailyBalancesAggregationTests {

  @Test("populates investment account ids regardless of persisted valuation mode")
  func populatesInvestmentAccountIds() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let tradesAccount = Account(
      id: UUID(), name: "Trades Account", type: .investment,
      instrument: .defaultTestInstrument,
      valuationMode: .calculatedFromTrades)
    _ = try await backend.accounts.create(tradesAccount)
    let snapshotAccount = Account(
      id: UUID(), name: "Snapshot Account", type: .investment,
      instrument: .defaultTestInstrument,
      valuationMode: .recordedValue)
    _ = try await backend.accounts.create(snapshotAccount)

    let aggregation = try await backend.fetchAggregationForTesting(
      after: nil, forecastUntil: nil)

    #expect(aggregation.investmentAccountIds.contains(tradesAccount.id))
    #expect(aggregation.investmentAccountIds.contains(snapshotAccount.id))
  }

  @Test("position rows include every investment account and exclude bank accounts")
  func filtersAccountRowsByMode() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let tradesAccount = Account(
      id: UUID(), name: "Trades Account", type: .investment,
      instrument: .defaultTestInstrument,
      valuationMode: .calculatedFromTrades)
    _ = try await backend.accounts.create(tradesAccount)
    let snapshotAccount = Account(
      id: UUID(), name: "Snapshot Account", type: .investment,
      instrument: .defaultTestInstrument,
      valuationMode: .recordedValue)
    _ = try await backend.accounts.create(snapshotAccount)
    let bankAccount = Account(
      id: UUID(), name: "Cash", type: .bank,
      instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(bankAccount)

    let cutoff = try AnalysisTestHelpers.date(year: 2025, month: 6, day: 1)
    let priorDate = try AnalysisTestHelpers.date(year: 2025, month: 5, day: 15)
    let postDate = try AnalysisTestHelpers.date(year: 2025, month: 6, day: 15)

    // One transaction on each side of the cutoff for each account.
    for (account, date) in [
      (tradesAccount, priorDate), (tradesAccount, postDate),
      (snapshotAccount, priorDate), (snapshotAccount, postDate),
      (bankAccount, priorDate), (bankAccount, postDate),
    ] {
      _ = try await backend.transactions.create(
        Transaction(
          date: date, payee: "Tick",
          legs: [
            TransactionLeg(
              accountId: account.id, instrument: .defaultTestInstrument,
              quantity: 10, type: .income)
          ]))
    }

    let aggregation = try await backend.fetchAggregationForTesting(
      after: cutoff, forecastUntil: nil)

    let priorIds = Set(aggregation.priorInvestmentAccountRows.map(\.accountId))
    let postIds = Set(aggregation.investmentAccountRows.map(\.accountId))
    #expect(priorIds == [tradesAccount.id, snapshotAccount.id])
    #expect(postIds == [tradesAccount.id, snapshotAccount.id])
  }

  @Test("recorded-value-only profile still produces position inputs")
  func recordedValueProfileProducesPositionInputs() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let snapshotAccount = Account(
      id: UUID(), name: "Snapshot Account", type: .investment,
      instrument: .defaultTestInstrument,
      valuationMode: .recordedValue)
    _ = try await backend.accounts.create(snapshotAccount)

    let aggregation = try await backend.fetchAggregationForTesting(
      after: nil, forecastUntil: nil)

    #expect(aggregation.investmentAccountIds == [snapshotAccount.id])
    #expect(aggregation.priorInvestmentAccountRows.isEmpty)
    #expect(aggregation.investmentAccountRows.isEmpty)
  }
}
