import Foundation
import Testing

@testable import Moolah

struct ReadSummaryCalculationTests {
  @Test
  func historicalFlowsAndCurrentNetWorthUseDifferentExplicitDates() async throws {
    let aud = Instrument.fiat(code: "AUD")
    let first = Date(timeIntervalSince1970: 1_700_006_400)
    let second = first.addingTimeInterval(86400)
    let current = second.addingTimeInterval(86400)
    let conversion = FakeConversionService.dateRates([
      first: ["USD": 2], second: ["USD": 3], current: ["USD": 4],
    ])
    let calculation = ReadFinancialCalculationService(conversion: conversion)
    let snapshot = fixtureSnapshot(first: first, second: second, current: current)
    let (result, warnings) = try await calculation.summary(
      snapshot,
      target: aud,
      grouping: .category
    )
    #expect(result.reportingIncome.value?.quantity == "120")
    #expect(result.reportingSpending.value?.quantity == "-35")
    #expect(result.currentNetWorth?.value?.quantity == "100")
    #expect(result.currentNetWorth?.requestedAt == current)
    #expect(result.reportingIncome.requestedAt == nil)
    #expect(result.income.map(\.quantity) == ["100", "10"])
    #expect(result.spending.map(\.quantity) == ["-20", "-5"])
    #expect(result.groups.count == 2)
    #expect(warnings.contains { $0.contains("Provider names aren’t available") })
    #expect(conversion.recordedBatches.flatMap { $0 }.map(\.date).contains(current))
  }
  private func fixtureSnapshot(first: Date, second: Date, current: Date) -> ReadSummarySnapshot {
    let aud = Instrument.fiat(code: "AUD")
    let usd = Instrument.fiat(code: "USD")
    let salary = UUID()
    let groceries = UUID()
    return ReadSummarySnapshot(
      flows: [
        (first, salary, TransactionType.income, 100, aud),
        (first, salary, .income, 10, usd),
        (second, groceries, .expense, -20, aud),
        (second, groceries, .expense, -5, usd),
        (first, salary, .openingBalance, 5000, aud),
        (first, salary, .transfer, 5000, aud),
      ].map { date, category, type, quantity, instrument in
        ReadSummaryFlow(
          date: date,
          categoryID: category,
          type: type,
          amount: InstrumentAmount(quantity: Decimal(quantity), instrument: instrument)
        )
      },
      netWorth: .requested([
        ReadBalanceInput(
          accountID: UUID(),
          positions: [
            InstrumentAmount(quantity: 80, instrument: aud),
            InstrumentAmount(quantity: 10, instrument: usd),
          ],
          accountName: nil
        ),
        ReadBalanceInput(
          accountID: UUID(),
          positions: [InstrumentAmount(quantity: -5, instrument: usd)],
          accountName: nil
        ),
      ]),
      categories: [
        ReadCategoryDTO(id: salary, name: "Salary", parentID: nil),
        ReadCategoryDTO(id: groceries, name: "Groceries", parentID: nil),
      ],
      timeZone: .utc,
      revision: "fixture",
      queriedAt: current
    )
  }

}

extension ReadSummaryCalculationTests {
  @Test(arguments: ["America/Los_Angeles", "Australia/Brisbane", "Pacific/Kiritimati"])
  func reportDaysStayUTCAtLocalMidnightBoundaries(zoneID: String) async throws {
    let zone = try #require(TimeZone(identifier: zoneID))
    let formatter = ISO8601DateFormatter()
    let before = try #require(formatter.date(from: "2026-01-02T23:59:59Z"))
    let after = try #require(formatter.date(from: "2026-01-03T00:00:01Z"))
    let firstDay = try #require(formatter.date(from: "2026-01-02T00:00:00Z"))
    let secondDay = try #require(formatter.date(from: "2026-01-03T00:00:00Z"))
    var local = Calendar(identifier: .gregorian)
    local.timeZone = zone
    #expect(local.startOfDay(for: before) != firstDay)
    #expect(local.startOfDay(for: after) != secondDay)
    let conversion = FakeConversionService.dateRates([firstDay: ["USD": 2], secondDay: ["USD": 3]])
    let usd = Instrument.fiat(code: "USD")
    let snapshot = ReadSummarySnapshot(
      flows: [before, after].map {
        ReadSummaryFlow(
          date: $0,
          categoryID: nil,
          type: .income,
          amount: InstrumentAmount(quantity: 1, instrument: usd)
        )
      },
      netWorth: .requested([]),
      categories: [],
      timeZone: zone,
      revision: "fixture",
      queriedAt: after
    )
    let (result, _) = try await ReadFinancialCalculationService(conversion: conversion).summary(
      snapshot,
      target: .fiat(code: "AUD"),
      grouping: .none
    )
    #expect(result.reportingIncome.value?.quantity == "5")
    #expect(conversion.recordedBatches.flatMap { $0 }.map(\.date) == [firstDay, secondDay])
  }
}

extension ReadSummaryCalculationTests {
  @Test
  func omittedNetWorthMakesNoLifetimePriceRequests() async throws {
    let conversion = FakeConversionService.alwaysThrows
    let snapshot = ReadSummarySnapshot(
      flows: [],
      netWorth: .omitted,
      categories: [],
      timeZone: .utc,
      revision: "fixture",
      queriedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let (summary, _) = try await ReadFinancialCalculationService(conversion: conversion).summary(
      snapshot,
      target: .defaultTestInstrument,
      grouping: .none
    )
    #expect(!summary.netWorthIncluded)
    #expect(summary.currentNetWorth == nil)
    #expect(conversion.recordedBatches.isEmpty)
    let json = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(summary)) as? [String: Any]
    )
    #expect(json["netWorthIncluded"] as? Bool == false)
    #expect(json["currentNetWorth"] == nil)
  }
}
