import Foundation
import Testing

@testable import Moolah

struct ReadSummaryGroupingTests {
  let household: UUID
  let groceries: UUID
  let utilities: UUID

  init() throws {
    household = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
    groceries = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
    utilities = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000003"))
  }

  @Test
  func monthlyCategoryGroupsIncludeNamedHouseholdTotalsWithoutDoubleCountingOverallSpending()
    async throws
  {
    let snapshot = try snapshot()
    let (result, _) = try await ReadFinancialCalculationService(
      conversion: FakeConversionService.alwaysThrows
    )
    .summary(snapshot, target: .defaultTestInstrument, grouping: .categoryMonth)
    #expect(result.reportingSpending.value?.quantity == "-28")
    let january = try #require(
      result.groups.first { $0.categoryID == household && $0.month == "2026-01" }
    )
    #expect(january.categoryName == "Household")
    #expect(january.reportingSpending.value?.quantity == "-30")
    #expect(january.includesDescendants)
    let child = try #require(
      result.groups.first { $0.categoryID == groceries && $0.month == "2026-02" }
    )
    #expect(child.categoryName == "Groceries")
    #expect(child.parentCategoryID == household)
    #expect(child.reportingSpending.value?.quantity == "2")
  }

  @Test
  func parentTotalsCanBeOmittedWithoutLosingCategoryNames() async throws {
    let (result, _) = try await ReadFinancialCalculationService(
      conversion: FakeConversionService.alwaysThrows
    )
    .summary(
      try snapshot(),
      target: .defaultTestInstrument,
      grouping: .category,
      includeParentTotals: false
    )
    #expect(!result.groups.contains { $0.categoryID == household })
    #expect(result.groups.allSatisfy { !$0.includesDescendants })
    #expect(result.groups.first { $0.categoryID == groceries }?.categoryName == "Groceries")
  }

  @Test
  func monthlyConversionsUseEachUTCPriceDay() async throws {
    let first = try instant("2026-01-01T00:00:00Z")
    let second = try instant("2026-01-02T00:00:00Z")
    let conversion = FakeConversionService.dateRates([first: ["USD": 2], second: ["USD": 3]])
    let input = ReadSummarySnapshot(
      flows: [first, second].map {
        ReadSummaryFlow(
          date: $0,
          categoryID: nil,
          type: .expense,
          amount: InstrumentAmount(quantity: -1, instrument: .fiat(code: "USD"))
        )
      },
      netWorth: .omitted,
      categories: [],
      timeZone: .utc,
      revision: "fixture",
      queriedAt: second
    )
    let (result, _) = try await ReadFinancialCalculationService(conversion: conversion)
      .summary(input, target: .fiat(code: "AUD"), grouping: .month)
    #expect(result.groups.count == 1)
    #expect(result.groups.first?.month == "2026-01")
    #expect(result.groups.first?.reportingSpending.value?.quantity == "-5")
    #expect(conversion.recordedBatches.flatMap { $0 }.map(\.date) == [first, second])
  }

  @Test(arguments: ["America/Los_Angeles", "Pacific/Kiritimati", "Australia/Brisbane"])
  func monthlyGroupsStaySeparateWithinOneUTCPriceDay(zoneID: String) async throws {
    let zone = try #require(TimeZone(identifier: zoneID))
    var calendar = Calendar.utc
    calendar.timeZone = zone
    let boundary = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 1)))
    let day = Calendar.utc.startOfDay(for: boundary)
    let conversion = FakeConversionService.dateRates([day: ["USD": 2]])
    let input = ReadSummarySnapshot(
      flows: [-1.0, 1].map {
        ReadSummaryFlow(
          date: boundary.addingTimeInterval($0),
          categoryID: nil,
          type: .income,
          amount: InstrumentAmount(quantity: 1, instrument: .fiat(code: "USD"))
        )
      },
      netWorth: .omitted,
      categories: [],
      timeZone: zone,
      revision: "fixture",
      queriedAt: boundary
    )
    let (result, _) = try await ReadFinancialCalculationService(conversion: conversion)
      .summary(input, target: .fiat(code: "AUD"), grouping: .month)
    #expect(result.groups.map(\.month) == ["2026-02", "2026-03"])
    #expect(result.groups.map { $0.reportingIncome.value?.quantity } == ["2", "2"])
    #expect(conversion.recordedBatches.flatMap { $0 }.allSatisfy { $0.date == day })
  }

  @Test
  func cyclicCategoriesFailRatherThanReturningMisleadingParentTotals() async throws {
    let input = ReadSummarySnapshot(
      flows: [
        ReadSummaryFlow(
          date: try instant("2026-01-01T00:00:00Z"),
          categoryID: groceries,
          type: .expense,
          amount: InstrumentAmount(quantity: -1, instrument: .defaultTestInstrument)
        )
      ],
      netWorth: .omitted,
      categories: [ReadCategoryDTO(id: groceries, name: "Cycle", parentID: groceries)],
      timeZone: .utc,
      revision: "fixture",
      queriedAt: try instant("2026-01-01T00:00:00Z")
    )
    await #expect(throws: ReadCalculationError.invalidResult) {
      try await ReadFinancialCalculationService(conversion: FakeConversionService.alwaysThrows)
        .summary(input, target: .defaultTestInstrument, grouping: .category)
    }
  }

  private func instant(_ text: String) throws -> Date {
    try #require(ISO8601DateFormatter().date(from: text))
  }

  private func snapshot() throws -> ReadSummarySnapshot {
    let january = try instant("2026-01-01T12:00:00Z")
    let february = try instant("2026-02-01T12:00:00Z")
    return ReadSummarySnapshot(
      flows: [
        ReadSummaryFlow(
          date: january,
          categoryID: groceries,
          type: .expense,
          amount: InstrumentAmount(quantity: -10, instrument: .defaultTestInstrument)
        ),
        ReadSummaryFlow(
          date: january,
          categoryID: utilities,
          type: .expense,
          amount: InstrumentAmount(quantity: -20, instrument: .defaultTestInstrument)
        ),
        ReadSummaryFlow(
          date: february,
          categoryID: groceries,
          type: .expense,
          amount: InstrumentAmount(quantity: 2, instrument: .defaultTestInstrument)
        ),
      ],
      netWorth: .omitted,
      categories: [
        ReadCategoryDTO(id: household, name: "Household", parentID: nil),
        ReadCategoryDTO(id: groceries, name: "Groceries", parentID: household),
        ReadCategoryDTO(id: utilities, name: "Utilities", parentID: household),
      ],
      timeZone: .utc,
      revision: "fixture",
      queriedAt: february
    )
  }
}

extension ReadSummaryGroupingTests {
  @Test
  func missingPricesLeaveIndependentSiblingsAvailableButInvalidateParentTotals() async throws {
    let original = try snapshot()
    let flows = original.flows.map { flow in
      ReadSummaryFlow(
        date: flow.date,
        categoryID: flow.categoryID,
        type: flow.type,
        amount: InstrumentAmount(
          quantity: flow.amount.quantity,
          instrument: flow.categoryID == utilities ? .fiat(code: "USD") : .defaultTestInstrument
        )
      )
    }
    let input = ReadSummarySnapshot(
      flows: flows,
      netWorth: .omitted,
      categories: original.categories,
      timeZone: original.timeZone,
      revision: original.revision,
      queriedAt: original.queriedAt
    )
    let (result, _) = try await ReadFinancialCalculationService(
      conversion: FakeConversionService { request, _ in
        .failure(ConversionError.noProviderMapping(instrumentId: request.from.id))
      }
    )
    .summary(input, target: .defaultTestInstrument, grouping: .category)
    #expect(result.reportingSpending.value == nil)
    #expect(result.groups.first { $0.categoryID == household }?.reportingSpending.value == nil)
    #expect(
      result.groups.first { $0.categoryID == groceries }?.reportingSpending.value?.quantity == "-8"
    )
  }

  @Test
  func monthlyCategoryOutputHasItsOwnBound() async throws {
    let start = try instant("2020-01-01T00:00:00Z")
    let categories = (0..<6).map {
      ReadCategoryDTO(id: UUID(), name: "Category \($0)", parentID: nil)
    }
    var flows: [ReadSummaryFlow] = []
    for index in 0..<84 {
      let date = try #require(Calendar.utc.date(byAdding: .month, value: index, to: start))
      for category in categories {
        flows.append(
          ReadSummaryFlow(
            date: date,
            categoryID: category.id,
            type: .expense,
            amount: InstrumentAmount(quantity: -1, instrument: .defaultTestInstrument)
          )
        )
      }
    }
    let input = ReadSummarySnapshot(
      flows: flows,
      netWorth: .omitted,
      categories: categories,
      timeZone: .utc,
      revision: "fixture",
      queriedAt: start
    )
    await #expect(
      throws: ReadLimitError(operation: .summaryGroups, unit: .calculationGroups, maximum: 500)
    ) {
      try await ReadFinancialCalculationService(conversion: FakeConversionService.alwaysThrows)
        .summary(input, target: .defaultTestInstrument, grouping: .categoryMonth)
    }
  }
}

extension ReadSummaryGroupingTests {
  @Test(arguments: [false, true])
  func malformedCategoryMetadataFailsClosed(duplicate: Bool) async throws {
    let original = try snapshot()
    let categories = duplicate ? original.categories + [original.categories[0]] : []
    let input = ReadSummarySnapshot(
      flows: original.flows,
      netWorth: .omitted,
      categories: categories,
      timeZone: .utc,
      revision: "fixture",
      queriedAt: original.queriedAt
    )
    await #expect(throws: ReadCalculationError.invalidResult) {
      try await ReadFinancialCalculationService(conversion: FakeConversionService.alwaysThrows)
        .summary(
          input,
          target: .defaultTestInstrument,
          grouping: .category,
          includeParentTotals: false
        )
    }
  }

  @Test
  func uncategorisedRowsDoNotClaimToIncludeDescendants() async throws {
    let date = try instant("2026-01-01T00:00:00Z")
    let input = ReadSummarySnapshot(
      flows: [
        ReadSummaryFlow(
          date: date,
          categoryID: nil,
          type: .expense,
          amount: InstrumentAmount(quantity: -1, instrument: .defaultTestInstrument)
        )
      ],
      netWorth: .omitted,
      categories: [],
      timeZone: .utc,
      revision: "fixture",
      queriedAt: date
    )
    let (result, _) = try await ReadFinancialCalculationService(
      conversion: FakeConversionService.alwaysThrows
    )
    .summary(input, target: .defaultTestInstrument, grouping: .category)
    #expect(result.groups.count == 1)
    #expect(result.groups.first?.includesDescendants == false)
  }
}
