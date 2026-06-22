import Foundation
import Testing

@testable import Moolah

/// Pins the protocol-extension default implementation of
/// `convertResultBatch(_:)` on `InstrumentConversionService`. The default
/// loops `convertResult` per request, folding each into a
/// `BatchConversionOutcome`, and rethrows `CancellationError`.
///
/// Exercised through `DefaultBatchTestService` — a minimal conformer that
/// deliberately does NOT override `convertResultBatch`, so it inherits the
/// protocol-extension default. `FakeConversionService` overrides the method,
/// so it cannot pin the inherited behaviour; those override-specific
/// assertions live in `FakeConversionServiceTests`.
@Suite("InstrumentConversionService.convertResultBatch default")
struct InstrumentConversionBatchTests {
  private let usd = Instrument.USD
  private let aud = Instrument.AUD
  private let eur = Instrument.fiat(code: "EUR")

  private func date(_ string: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return try #require(formatter.date(from: string))
  }

  private func request(
    _ quantity: Decimal, from: Instrument, to: Instrument, on date: Date
  ) -> BatchConversionRequest {
    BatchConversionRequest(
      amount: InstrumentAmount(quantity: quantity, instrument: from),
      target: to,
      date: date)
  }

  /// Outcomes come back in request order, one per request.
  @Test
  func preservesRequestOrder() async throws {
    let service = DefaultBatchTestService(rates: ["USD": dec("2"), "EUR": dec("3")])
    let day = try date("2025-06-15")
    let requests = [
      request(dec("10"), from: usd, to: aud, on: day),
      request(dec("10"), from: eur, to: aud, on: day),
      request(dec("10"), from: usd, to: aud, on: day),
    ]

    let outcomes = try await service.convertResultBatch(requests)

    #expect(outcomes.count == 3)
    guard case .value(let first) = outcomes[0] else {
      Issue.record("expected .value, got \(outcomes[0])")
      return
    }
    guard case .value(let second) = outcomes[1] else {
      Issue.record("expected .value, got \(outcomes[1])")
      return
    }
    guard case .value(let third) = outcomes[2] else {
      Issue.record("expected .value, got \(outcomes[2])")
      return
    }
    #expect(first.quantity == dec("20"))
    #expect(second.quantity == dec("30"))
    #expect(third.quantity == dec("20"))
  }

  /// A same-instrument request folds to `.value` carrying the input amount.
  @Test
  func sameInstrumentFoldsToValue() async throws {
    let service = DefaultBatchTestService()
    let day = try date("2025-06-15")
    let outcomes = try await service.convertResultBatch([
      request(dec("42"), from: usd, to: usd, on: day)
    ])

    guard case .value(let amount) = outcomes[0] else {
      Issue.record("expected .value, got \(outcomes[0])")
      return
    }
    #expect(amount == InstrumentAmount(quantity: dec("42"), instrument: usd))
  }

  /// A `.knownZero` from `convertResult` folds to `.knownZero` carrying the
  /// target instrument.
  @Test
  func knownZeroFoldsToKnownZero() async throws {
    let service = DefaultBatchTestService(knownZero: ["USD"])
    let day = try date("2025-06-15")
    let outcomes = try await service.convertResultBatch([
      request(dec("10"), from: usd, to: aud, on: day)
    ])

    guard case .knownZero(let target) = outcomes[0] else {
      Issue.record("expected .knownZero, got \(outcomes[0])")
      return
    }
    #expect(target == aud)
  }

  /// A thrown (non-cancellation) error from `convertResult` folds to
  /// `.failure` for that element — the batch as a whole still succeeds.
  @Test
  func perElementFailureFoldsToFailure() async throws {
    let service = DefaultBatchTestService(failing: ["EUR"])
    let day = try date("2025-06-15")
    let requests = [
      request(dec("10"), from: usd, to: aud, on: day),
      request(dec("10"), from: eur, to: aud, on: day),
    ]

    let outcomes = try await service.convertResultBatch(requests)

    guard case .value = outcomes[0] else {
      Issue.record("expected .value, got \(outcomes[0])")
      return
    }
    guard case .failure(let error) = outcomes[1] else {
      Issue.record("expected .failure, got \(outcomes[1])")
      return
    }
    #expect(
      error as? DefaultBatchTestError == .instrumentUnavailable(instrumentId: "EUR"))
  }

  /// A cancelled task makes the batch rethrow `CancellationError` rather
  /// than returning partial outcomes — cancellation is task-wide, not
  /// per-element.
  @Test
  func rethrowsCancellationError() async throws {
    let service = DefaultBatchTestService()
    let day = try date("2025-06-15")
    let requests = (0..<8).map { _ in
      request(dec("1"), from: usd, to: aud, on: day)
    }

    let task = Task {
      try await service.convertResultBatch(requests)
    }
    task.cancel()

    await #expect(throws: CancellationError.self) {
      _ = try await task.value
    }
  }
}

/// Errors surfaced by `DefaultBatchTestService.convertResult` for the
/// failing-instrument scenario.
private enum DefaultBatchTestError: Error, Equatable {
  case instrumentUnavailable(instrumentId: String)
}

/// Minimal `InstrumentConversionService` conformer that deliberately does
/// NOT override `convertResultBatch(_:)`, so it inherits the
/// protocol-extension default. Used to pin the inherited batch behaviour
/// (order, `.value` / `.knownZero` / `.failure` folding, cancellation) that
/// every non-overriding conformer gets for free.
///
/// Only `convertResult` carries behaviour; `convert` / `convertAmount` are
/// trivial because the default batch path routes through `convertResult`.
private final class DefaultBatchTestService: InstrumentConversionService, Sendable {
  /// Per-source-id multiplier applied by `convertResult`, 1:1 fallback.
  private let rates: [String: Decimal]
  /// Source ids that resolve to `.knownZero`.
  private let knownZero: Set<String>
  /// Source ids that throw `DefaultBatchTestError.instrumentUnavailable`.
  private let failing: Set<String>

  init(
    rates: [String: Decimal] = [:],
    knownZero: Set<String> = [],
    failing: Set<String> = []
  ) {
    self.rates = rates
    self.knownZero = knownZero
    self.failing = failing
  }

  func convert(
    _ quantity: Decimal, from: Instrument, to: Instrument, on date: Date
  ) async throws -> Decimal {
    if from.id == to.id { return quantity }
    if failing.contains(from.id) {
      throw DefaultBatchTestError.instrumentUnavailable(instrumentId: from.id)
    }
    return quantity * (rates[from.id] ?? 1)
  }

  func convertAmount(
    _ amount: InstrumentAmount, to instrument: Instrument, on date: Date
  ) async throws -> InstrumentAmount {
    guard amount.instrument != instrument else { return amount }
    let converted = try await convert(
      amount.quantity, from: amount.instrument, to: instrument, on: date)
    return InstrumentAmount(quantity: converted, instrument: instrument)
  }

  func convertResult(
    _ amount: InstrumentAmount, to instrument: Instrument, on date: Date
  ) async throws -> ConversionResult {
    if amount.instrument == instrument { return .value(amount) }
    if knownZero.contains(amount.instrument.id) {
      return .knownZero(targetInstrument: instrument)
    }
    return .value(try await convertAmount(amount, to: instrument, on: date))
  }

  func invalidateCache(for instrument: Instrument) async {}

  func observeRates() -> AsyncStream<Void> {
    AsyncStream { $0.finish() }
  }

  func observeErrors() -> AsyncStream<any Error> {
    AsyncStream { $0.finish() }
  }
}
