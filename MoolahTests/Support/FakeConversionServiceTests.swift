import Foundation
import Testing

@testable import Moolah

/// Exercises every `FakeConversionService` factory and its
/// recording / rate-tick behaviour, so the consolidated double is proven
/// before the nine old doubles are migrated onto it.
@Suite
struct FakeConversionServiceTests {
  private let aud = Instrument.AUD
  private let usd = Instrument.USD
  private let date = Date(timeIntervalSince1970: 1_000_000)

  @Test
  func passthroughReturnsInputUnchanged() async throws {
    let service = FakeConversionService.passthrough
    let result = try await service.convert(42, from: usd, to: aud, on: date)
    #expect(result == 42)

    let amount = InstrumentAmount(quantity: 10, instrument: usd)
    let converted = try await service.convertAmount(amount, to: aud, on: date)
    #expect(converted == InstrumentAmount(quantity: 10, instrument: aud))
  }

  @Test
  func sameInstrumentSkipsOutcomeButRecordsConvert() async throws {
    let service = FakeConversionService.alwaysThrows
    // Same instrument must NOT reach the always-throwing outcome and must
    // NOT advance `callCount` (the rate-logic counter).
    let raw = try await service.convert(5, from: aud, to: aud, on: date)
    #expect(raw == 5)
    let amount = InstrumentAmount(quantity: 5, instrument: aud)
    let result = try await service.convertResult(amount, to: aud, on: date)
    #expect(result == .value(amount))
    #expect(service.callCount == 0)
    // But `convert` still records the same-instrument call, matching the
    // old `RecordingConversionService` (which never short-circuited).
    // `convertResult` returns its `.value` without routing through
    // `convert`, so only the direct `convert` call is recorded.
    #expect(service.recordedCalls.count == 1)
    #expect(service.recordedCalls.first?.quantity == 5)
    #expect(service.recordedCalls.first?.from == aud)
    #expect(service.recordedCalls.first?.to == aud)
  }

  @Test
  func fixedRatesAppliesRateThenFallsBackOneToOne() async throws {
    let service = FakeConversionService.fixedRates([usd.id: 2])
    let scaled = try await service.convert(3, from: usd, to: aud, on: date)
    #expect(scaled == 6)
    // No rate for an unknown source → 1:1 fallback.
    let eur = Instrument.fiat(code: "EUR")
    let fallback = try await service.convert(7, from: eur, to: aud, on: date)
    #expect(fallback == 7)
  }

  @Test
  func fixedRatesKnownZeroResultVsThrow() async throws {
    let service = FakeConversionService.fixedRates([:], knownZero: [usd.id])
    let amount = InstrumentAmount(quantity: 9, instrument: usd)
    let result = try await service.convertResult(amount, to: aud, on: date)
    #expect(result == .knownZero(targetInstrument: aud))
    // The `convert` path surfaces the known-zero source as an error.
    await #expect(throws: FakeConversionError.knownZeroSource(instrumentId: usd.id)) {
      _ = try await service.convert(9, from: usd, to: aud, on: date)
    }
  }

  @Test
  func dateRatesPicksMostRecentDateOnOrBeforeRequest() async throws {
    let early = Date(timeIntervalSince1970: 0)
    let late = Date(timeIntervalSince1970: 2_000_000)
    let service = FakeConversionService.dateRates([
      early: [usd.id: 2],
      late: [usd.id: 5],
    ])
    // Request between the two → uses the earlier (2x) rate.
    let mid = try await service.convert(1, from: usd, to: aud, on: date)
    #expect(mid == 2)
    // Request at/after the late date → uses the 5x rate.
    let after = try await service.convert(1, from: usd, to: aud, on: late)
    #expect(after == 5)
    // Request before any rate → 1:1 fallback.
    let before = try await service.convert(
      1, from: usd, to: aud, on: Date(timeIntervalSince1970: -10))
    #expect(before == 1)
  }

  @Test
  func dateRatesFailsOnFailingDates() async throws {
    let service = FakeConversionService.dateRates(
      [Date(timeIntervalSince1970: 0): [usd.id: 2]], failingDates: [date])
    await #expect(throws: FakeConversionError.dateUnavailable(date: date)) {
      _ = try await service.convert(1, from: usd, to: aud, on: date)
    }
  }

  @Test
  func failingInstrumentsToggleAtRuntime() async throws {
    let service = FakeConversionService.failingInstruments(rates: [usd.id: 2])
    // Initially succeeds.
    let ok = try await service.convert(3, from: usd, to: aud, on: date)
    #expect(ok == 6)
    // Toggle the source instrument into the failing set.
    service.setFailing([usd.id])
    await #expect(throws: FakeConversionError.instrumentUnavailable(instrumentId: usd.id)) {
      _ = try await service.convert(3, from: usd, to: aud, on: date)
    }
    // Failing the destination also throws.
    service.setFailing([aud.id])
    await #expect(throws: FakeConversionError.instrumentUnavailable(instrumentId: aud.id)) {
      _ = try await service.convert(3, from: usd, to: aud, on: date)
    }
  }

  @Test
  func alwaysThrowsOnEveryConversion() async throws {
    let service = FakeConversionService.alwaysThrows
    await #expect(throws: FakeConversionError.invoked) {
      _ = try await service.convert(1, from: usd, to: aud, on: date)
    }
    let amount = InstrumentAmount(quantity: 1, instrument: usd)
    await #expect(throws: FakeConversionError.invoked) {
      _ = try await service.convertResult(amount, to: aud, on: date)
    }
  }

  @Test
  func perCallFailsAtSpecificIndices() async throws {
    let service = FakeConversionService.perCall { index in
      index == 1 ? .failure(FakeConversionError.invoked) : .success(Decimal(index))
    }
    let first = try await service.convert(0, from: usd, to: aud, on: date)
    #expect(first == 0)
    await #expect(throws: FakeConversionError.invoked) {
      _ = try await service.convert(0, from: usd, to: aud, on: date)
    }
    let third = try await service.convert(0, from: usd, to: aud, on: date)
    #expect(third == 2)
    #expect(service.callCount == 3)
  }

  @Test
  func recordsConvertCallsAndCounts() async throws {
    let service = FakeConversionService.passthrough
    _ = try await service.convertAmount(
      InstrumentAmount(quantity: 1, instrument: usd), to: aud, on: date)
    // Same-instrument convertAmount counts but does not record a convert.
    _ = try await service.convertAmount(
      InstrumentAmount(quantity: 1, instrument: aud), to: aud, on: date)
    #expect(service.convertAmountCallCount == 2)
    #expect(service.callCount == 1)
    #expect(
      service.recordedCalls == [
        RecordingConversionServiceCall(quantity: 1, from: usd, to: aud, date: date)
      ])
  }

  @Test
  func recordsInvalidations() async {
    let service = FakeConversionService.passthrough
    await service.invalidateCache(for: usd)
    await service.invalidateCache(for: usd)
    #expect(service.invalidatedInstruments == [usd, usd])
  }

  @Test
  func observeRatesEmitsInitialTickThenOnEmit() async throws {
    let service = FakeConversionService.passthrough
    var iterator = service.observeRates().makeAsyncIterator()
    // Initial on-subscribe tick.
    #expect(await iterator.next() != nil)
    service.emitRate()
    #expect(await iterator.next() != nil)
  }

  @Test
  func observeErrorsFinishesEmpty() async {
    let service = FakeConversionService.passthrough
    var iterator = service.observeErrors().makeAsyncIterator()
    #expect(await iterator.next() == nil)
  }
}
