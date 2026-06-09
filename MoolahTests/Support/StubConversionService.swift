import Foundation

@testable import Moolah

/// Minimal `InstrumentConversionService` test double whose rate-tick
/// stream is controllable from the test. On subscription it yields ONE
/// initial tick (matching the production `observeRates()` contract), then
/// re-emits each time the test calls `emitRate()`. Conversions are
/// pass-through (1:1) so the stub is usable wherever a real conversion
/// service isn't the thing under test. See issue #1075.
final class StubConversionService: InstrumentConversionService, @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: AsyncStream<Void>.Continuation?

  func convert(
    _ quantity: Decimal, from: Instrument, to: Instrument, on date: Date
  ) async throws -> Decimal {
    quantity
  }

  func convertAmount(
    _ amount: InstrumentAmount, to instrument: Instrument, on date: Date
  ) async throws -> InstrumentAmount {
    InstrumentAmount(quantity: amount.quantity, instrument: instrument)
  }

  func convertResult(
    _ amount: InstrumentAmount, to instrument: Instrument, on date: Date
  ) async throws -> ConversionResult {
    if amount.instrument == instrument { return .value(amount) }
    return .value(InstrumentAmount(quantity: amount.quantity, instrument: instrument))
  }

  func invalidateCache(for instrument: Instrument) async {}

  /// Emits an initial tick on subscribe, then one tick per `emitRate()`.
  func observeRates() -> AsyncStream<Void> {
    let pair = AsyncStream<Void>.makeStream()
    lock.withLock { continuation = pair.continuation }
    pair.continuation.yield(())  // initial on-subscribe tick
    return pair.stream
  }

  func observeErrors() -> AsyncStream<any Error> {
    AsyncStream { $0.finish() }
  }

  /// Push a non-initial rate tick (simulating a warm write landing).
  func emitRate() {
    lock.withLock { continuation }?.yield(())
  }
}
