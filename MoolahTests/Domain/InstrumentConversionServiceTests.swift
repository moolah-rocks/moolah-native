import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("InstrumentConversionService")
struct InstrumentConversionServiceTests {
  private func date(_ string: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    formatter.timeZone = .utc
    return try #require(formatter.date(from: string))
  }

  private func makeService(
    rates: [String: [String: Decimal]] = [:]
  ) throws -> FiatConversionService {
    let client = FixedRateClient(rates: rates)
    let exchangeRates = ExchangeRateService(
      client: client, database: try ProfileIndexDatabase.openInMemory())
    return FiatConversionService(exchangeRates: exchangeRates)
  }

  @Test
  func sameCurrencyReturnsIdentity() async throws {
    let service = try makeService()
    let result = try await service.convert(
      dec("100.00"),
      from: .AUD, to: .AUD,
      on: try date("2025-06-15")
    )
    #expect(result == dec("100.00"))
  }

  @Test
  func convertsAUDtoUSD() async throws {
    let service = try makeService(rates: [
      "2025-06-15": ["USD": dec("0.6500")]
    ])
    let result = try await service.convert(
      dec("1000.00"),
      from: .AUD, to: .USD,
      on: try date("2025-06-15")
    )
    #expect(result == dec("650.00"))
  }

  @Test
  func convertsUSDtoAUD() async throws {
    let service = try makeService(rates: [
      "2025-06-15": ["AUD": dec("1.5385")]
    ])
    let result = try await service.convert(
      dec("650.00"),
      from: .USD, to: .AUD,
      on: try date("2025-06-15")
    )
    #expect(result == dec("650.00") * dec("1.5385"))
  }

  @Test
  func convertAmount() async throws {
    let service = try makeService(rates: [
      "2025-06-15": ["USD": dec("0.6500")]
    ])
    let amount = InstrumentAmount(
      quantity: dec("1000.00"),
      instrument: .AUD
    )
    let result = try await service.convertAmount(
      amount, to: .USD, on: try date("2025-06-15")
    )
    #expect(result.instrument == .USD)
    #expect(result.quantity == dec("650.00"))
  }

  @Test
  func convertAmountSameCurrency() async throws {
    let service = try makeService()
    let amount = InstrumentAmount(
      quantity: dec("1000.00"),
      instrument: .AUD
    )
    let result = try await service.convertAmount(
      amount, to: .AUD, on: try date("2025-06-15")
    )
    #expect(result == amount)
  }

  @Test("fiat provenance reports the prior day that supplied a fallback rate")
  func fiatProvenanceReportsFallbackDay() async throws {
    let service = try makeService(rates: [
      "2025-06-13": ["USD": dec("0.6500")]
    ])
    let amount = InstrumentAmount(quantity: dec("1000.00"), instrument: .AUD)

    let effectiveDate = try await service.oldestPriceDate(
      for: amount, to: .USD, on: try date("2025-06-15"))
    let expectedDate = try date("2025-06-13")

    #expect(effectiveDate == expectedDate)
  }

  /// Scheduled transactions and forecast days carry future dates. Frankfurter
  /// has no future rates, so before the clamp, a cold cache + future date
  /// threw `noRateAvailable`. The service now clamps `on: date` to today, so
  /// future dates resolve against the latest available rate instead.
  @Test("convert clamps future dates to today when only past rates are available")
  func convertClampsFutureDatesToToday() async throws {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    formatter.timeZone = .utc
    let calendar = Calendar(identifier: .gregorian)
    let today = calendar.startOfDay(for: Date())
    let pastDate = try #require(calendar.date(byAdding: .day, value: -15, to: today))
    let pastKey = formatter.string(from: pastDate)
    let service = try makeService(rates: [
      pastKey: ["USD": dec("0.6500")]
    ])

    let future = try #require(calendar.date(byAdding: .day, value: 30, to: today))
    let result = try await service.convert(
      dec("1000.00"),
      from: .AUD, to: .USD,
      on: future
    )
    #expect(result == dec("650.00"))
  }

  @Test("convertAmount clamps future dates to today")
  func convertAmountClampsFutureDatesToToday() async throws {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    formatter.timeZone = .utc
    let calendar = Calendar(identifier: .gregorian)
    let today = calendar.startOfDay(for: Date())
    let pastKey = formatter.string(
      from: try #require(calendar.date(byAdding: .day, value: -3, to: today))
    )
    let service = try makeService(rates: [
      pastKey: ["USD": dec("0.6500")]
    ])

    let future = try #require(calendar.date(byAdding: .day, value: 7, to: today))
    let amount = InstrumentAmount(quantity: Decimal(1000), instrument: .AUD)
    let result = try await service.convertAmount(amount, to: .USD, on: future)
    #expect(result.instrument == .USD)
    #expect(result.quantity == Decimal(650))
  }
}
