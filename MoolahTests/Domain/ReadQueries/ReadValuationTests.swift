import Foundation
import Testing

@testable import Moolah

struct ReadValuationTests {
  private let aud = Instrument.fiat(code: "AUD")
  private let usd = Instrument.fiat(code: "USD")
  private let instant = Date(timeIntervalSince1970: 1_700_000_000)

  @Test
  func exactNativeAmountsSkipConversionEntirely() async throws {
    let conversion = FakeConversionService.alwaysThrows
    let calculation = ReadFinancialCalculationService(conversion: conversion)
    let quantity = try #require(Decimal(string: "90071992.54740993"))
    let values = try await calculation.value(
      [
        ReadDatedAmount(
          amount: InstrumentAmount(quantity: quantity, instrument: aud),
          date: instant
        )
      ],
      target: aud
    )
    #expect(values.first?.amount?.quantity == quantity)
    #expect(values.first?.dto.value?.quantity == "90071992.54740993")
    #expect(values.first?.oldestPriceAt == nil)
    #expect(conversion.recordedBatches.isEmpty)
  }

  @Test
  func missingPriceNeverBecomesZeroOrACompleteTotal() async throws {
    let rate = try #require(Decimal(string: "1.5"))
    let conversion = FakeConversionService { request, _ in
      if request.from.id == "USD" {
        return .success(
          .value(InstrumentAmount(quantity: request.quantity * rate, instrument: request.to))
        )
      }
      return .failure(ConversionError.noProviderMapping(instrumentId: request.from.id))
    }
    let calculation = ReadFinancialCalculationService(conversion: conversion)
    let stock = Instrument.stock(ticker: "FIXTURE", exchange: "TEST", name: "Fixture")
    let signed = try #require(Decimal(string: "-10.00000001"))
    let values = try await calculation.value(
      [
        ReadDatedAmount(amount: InstrumentAmount(quantity: signed, instrument: usd), date: instant),
        ReadDatedAmount(amount: InstrumentAmount(quantity: 3, instrument: stock), date: instant),
      ],
      target: aud
    )
    #expect(values[0].dto.value?.quantity == "-15.000000015")
    #expect(values[1].amount == nil)
    #expect(values[1].errorCode == "PRICE_UNAVAILABLE")
    #expect(calculation.total(values, target: aud, on: instant).amount == nil)
    let data = try JSONEncoder().encode(values[1].dto)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["value"] is NSNull)
    #expect(values[1].dto.reportingInstrument.id == "AUD")
  }

  @Test
  func pricingPolicyZeroIsExplicitAndDistinctFromMissingPrices() async throws {
    let calculation = ReadFinancialCalculationService(
      conversion: FakeConversionService.fixedRates([:], knownZero: ["USD"])
    )
    let values = try await calculation.value(
      [
        ReadDatedAmount(amount: InstrumentAmount(quantity: 5, instrument: usd), date: instant)
      ],
      target: aud
    )
    #expect(values[0].amount?.quantity == 0)
    #expect(values[0].status == "known_zero_by_policy")
    #expect(values[0].provenance == "moolah_pricing_policy")
    #expect(values[0].errorCode == nil)
    #expect(calculation.warnings(values).contains { $0.contains("pricing rules") })
  }

  @Test
  func unlikeValuationsCannotBeSummedAndCancellationPropagates() async throws {
    let calculation = ReadFinancialCalculationService(
      conversion: FakeConversionService.alwaysThrows
    )
    let value = ReadValuation(
      amount: InstrumentAmount(quantity: 12, instrument: usd),
      reportingInstrument: usd,
      status: "native",
      requestedAt: instant,
      oldestPriceAt: nil,
      provenance: "fixture",
      errorCode: nil
    )
    #expect(calculation.total([value], target: aud, on: instant).amount == nil)
    let cancelled = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await calculation.value(
        [
          ReadDatedAmount(amount: InstrumentAmount(quantity: 1, instrument: usd), date: instant)
        ],
        target: aud
      )
    }
    await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
  }
}

extension ReadValuationTests {
  @Test
  func unexpectedFailuresAndInvalidTargetsRejectTheQuery() async throws {
    let amount = ReadDatedAmount(
      amount: InstrumentAmount(quantity: 1, instrument: usd),
      date: instant
    )
    let unexpected = ReadFinancialCalculationService(conversion: FakeConversionService.alwaysThrows)
    await #expect(throws: FakeConversionError.invoked) {
      try await unexpected.value([amount], target: aud)
    }
    let invalid = ReadFinancialCalculationService(
      conversion: FakeConversionService { request, _ in
        .success(.value(InstrumentAmount(quantity: request.quantity, instrument: request.from)))
      }
    )
    await #expect(throws: ReadCalculationError.invalidResult) {
      try await invalid.value([amount], target: aud)
    }
  }

  @Test
  func aggregateFreshnessRequiresEveryPricedContributor() {
    let calculation = ReadFinancialCalculationService(
      conversion: FakeConversionService.alwaysThrows
    )
    func priced(_ date: Date?) -> ReadValuation {
      ReadValuation(
        amount: InstrumentAmount(quantity: 1, instrument: aud),
        reportingInstrument: aud,
        status: "priced",
        requestedAt: instant,
        oldestPriceAt: date,
        provenance: "fixture",
        errorCode: nil
      )
    }
    let earlier = instant.addingTimeInterval(-3600)
    #expect(
      calculation.total([priced(earlier), priced(nil)], target: aud, on: instant).oldestPriceAt
        == nil
    )
    #expect(
      calculation.total([priced(instant), priced(earlier)], target: aud, on: instant).oldestPriceAt
        == earlier
    )
  }
}

extension ReadValuationTests {
  @Test
  func allAccountsShareOneConversionBatchAndKeepIndependentTotals() async throws {
    let conversion = FakeConversionService { request, _ in
      if request.from.id == "USD" {
        return .success(
          .value(InstrumentAmount(quantity: request.quantity * 2, instrument: request.to))
        )
      }
      return .failure(ConversionError.noProviderMapping(instrumentId: request.from.id))
    }
    let calculation = ReadFinancialCalculationService(conversion: conversion)
    let stock = Instrument.stock(ticker: "FIXTURE", exchange: "TEST", name: "Fixture")
    let first = UUID()
    let second = UUID()
    let (items, _) = try await calculation.balances(
      [
        ReadBalanceInput(
          accountID: first,
          positions: [InstrumentAmount(quantity: 3, instrument: usd)],
          accountName: nil
        ),
        ReadBalanceInput(
          accountID: second,
          positions: [InstrumentAmount(quantity: 7, instrument: stock)],
          accountName: nil
        ),
      ],
      target: aud,
      on: instant
    )
    #expect(conversion.recordedBatches.count == 1)
    #expect(conversion.recordedBatches.first?.count == 2)
    #expect(items.map(\.accountID) == [first, second])
    #expect(items[0].total.value?.quantity == "6")
    #expect(items[1].total.value == nil)
    #expect(items[1].positions[0].native.quantity == "7")
  }
}

extension ReadValuationTests {
  @Test
  func compactAccountTotalsOmitPositionDetailsWithoutChangingTheTotal() async throws {
    let calculation = ReadFinancialCalculationService(
      conversion: FakeConversionService.fixedRates(["USD": 2])
    )
    let inputs = [
      ReadBalanceInput(
        accountID: UUID(),
        positions: [InstrumentAmount(quantity: 3, instrument: usd)],
        accountName: "Fixture"
      )
    ]
    let (detailed, _) = try await calculation.balances(inputs, target: aud, on: instant)
    let (compact, _) = try await calculation.balances(
      inputs,
      target: aud,
      on: instant,
      includePositions: false
    )
    #expect(detailed[0].total.value?.quantity == "6")
    #expect(compact[0].total.value?.quantity == "6")
    #expect(compact[0].positions.isEmpty)
    #expect(!compact[0].positionsIncluded)
    #expect(detailed[0].positionsIncluded)
    #expect(compact[0].accountName == "Fixture")
  }
}
