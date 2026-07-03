import Foundation
import os

@testable import Moolah

/// Error surfaced for an instrument in the runtime failing set.
enum GatingConversionError: Error { case unavailable }

/// A conversion double whose `convertResultBatch` can be paused mid-call
/// exactly once, so a test can force a stale recompute to publish *after* a
/// fresher authoritative snapshot has landed — the ordering that lets an
/// out-of-order recompute clobber the fresher published state (the #1209 bug
/// class). Conversions are 1:1 passthrough except for instruments in the
/// runtime failing set (`setFailing(_:)`); the gate is the other interesting
/// behaviour. `observeRates()` deliberately emits no initial tick so the only
/// recomputes are the ones the test drives explicitly.
final class GatingConversionService {
  private let armed = OSAllocatedUnfairLock(initialState: false)
  /// Instrument ids that fail conversion (either side). Toggle at runtime with
  /// `setFailing(_:)` to model a provider outage that later recovers.
  private let failing = OSAllocatedUnfairLock(initialState: Set<String>())
  private let reached: AsyncStream<Void>
  private let reachedContinuation: AsyncStream<Void>.Continuation
  private let gate: AsyncStream<Void>
  private let gateContinuation: AsyncStream<Void>.Continuation

  init() {
    let reachedPair = AsyncStream<Void>.makeStream()
    reached = reachedPair.stream
    reachedContinuation = reachedPair.continuation
    let gatePair = AsyncStream<Void>.makeStream()
    gate = gatePair.stream
    gateContinuation = gatePair.continuation
  }

  /// Arm the gate so the *next* `convertResultBatch` call suspends.
  func armGate() { armed.withLock { $0 = true } }

  /// Suspends until a gated `convertResultBatch` call has begun — by which
  /// point that recompute has already captured its input snapshot.
  func waitUntilGateReached() async {
    var iterator = reached.makeAsyncIterator()
    _ = await iterator.next()
  }

  /// Releases the suspended `convertResultBatch` call.
  func releaseGate() { gateContinuation.yield(()) }

  /// Replace the runtime failing-instrument set (either side of a conversion
  /// in the set fails). Pass `[]` to recover.
  func setFailing(_ ids: Set<String>) { failing.withLock { $0 = ids } }
}

extension GatingConversionService: InstrumentConversionService {
  func convertResultBatch(
    _ requests: [BatchConversionRequest]
  ) async throws -> [BatchConversionOutcome] {
    let shouldGate = armed.withLock { state -> Bool in
      let value = state
      state = false
      return value
    }
    if shouldGate {
      reachedContinuation.yield(())
      var iterator = gate.makeAsyncIterator()
      _ = await iterator.next()
    }
    let failingIds = failing.withLock { $0 }
    return requests.map { request in
      if failingIds.contains(request.amount.instrument.id)
        || failingIds.contains(request.target.id)
      {
        return .failure(GatingConversionError.unavailable)
      }
      return .value(InstrumentAmount(quantity: request.amount.quantity, instrument: request.target))
    }
  }

  func convert(
    _ quantity: Decimal, from: Instrument, to: Instrument, on date: Date
  ) async throws -> Decimal {
    try throwIfFailing(from, to)
    return quantity
  }

  func convertAmount(
    _ amount: InstrumentAmount, to instrument: Instrument, on date: Date
  ) async throws -> InstrumentAmount {
    try throwIfFailing(amount.instrument, instrument)
    return InstrumentAmount(quantity: amount.quantity, instrument: instrument)
  }

  func convertResult(
    _ amount: InstrumentAmount, to instrument: Instrument, on date: Date
  ) async throws -> ConversionResult {
    try throwIfFailing(amount.instrument, instrument)
    return .value(InstrumentAmount(quantity: amount.quantity, instrument: instrument))
  }

  private func throwIfFailing(_ from: Instrument, _ to: Instrument) throws {
    let failingIds = failing.withLock { $0 }
    if failingIds.contains(from.id) || failingIds.contains(to.id) {
      throw GatingConversionError.unavailable
    }
  }

  func invalidateCache(for instrument: Instrument) async {}
  func observeRates() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
  func observeErrors() -> AsyncStream<any Error> { AsyncStream { $0.finish() } }
}

extension GatingConversionService: @unchecked Sendable {}
