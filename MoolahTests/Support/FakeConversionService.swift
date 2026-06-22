import Foundation
import os

@testable import Moolah

/// Unified `InstrumentConversionService` test double. Replaces the nine
/// bespoke doubles (`StubConversionService`, `FixedConversionService`,
/// `DateBasedFixedConversionService`, `DateFailingConversionService`,
/// `FailingConversionService`, `CountingConversionService`,
/// `ThrowingConversionService`, `ThrowingCountingConversionService`,
/// `RecordingConversionService`) with a single configurable fake.
///
/// All behaviour funnels through one stored `@Sendable` outcome closure:
/// given a `ConversionRequest` and a zero-based call index, it returns a
/// `Result<ConversionResult, any Error>`. The static factories below build
/// that closure for each behaviour family so call sites stay readable.
///
/// Mutable state (call counters, recorded calls, invalidations, runtime
/// failing-instrument set, rate-tick continuation) is guarded by
/// `OSAllocatedUnfairLock`, matching the `RecordingConversionService` /
/// `ThrowingCountingConversionService` style, so the fake is `Sendable` and
/// usable from any isolation domain.
///
/// ## Same-instrument fast path
/// Like the doubles it replaces, `convert` short-circuits when
/// `from.id == to.id` and `convertAmount` / `convertResult` short-circuit
/// when `amount.instrument == instrument`: the outcome closure is *not*
/// invoked and the call index does not advance. This preserves the
/// "never call into rate logic on a no-op conversion" semantics that
/// `ThrowingConversionService`-style assertions rely on.
///
/// One exception: `convert` still appends the same-instrument call to
/// `recordedCalls` before the fast return, because the old
/// `RecordingConversionService` never short-circuited and tests assert on
/// the no-op call it recorded (e.g. an AUD→AUD pair leg). Recording is
/// independent of `callCount`, so this does not perturb the counters.
///
/// ## Call counting
/// - `callCount` counts invocations of `convert(_:from:to:on:)` that reach
///   the outcome closure (i.e. excluding the same-instrument fast path).
///   This matches `ThrowingCountingConversionService.calls`.
/// - `convertAmountCallCount` counts every `convertAmount(_:to:on:)` call,
///   including same-instrument early returns. This matches
///   `CountingConversionService.convertAmountCallCount`.
///
/// ## Batch path
/// `convertResultBatch(_:)` is overridden (rather than inheriting the
/// protocol default) so it records the request set (`recordedBatches`)
/// for batch-era assertions and resolves each element through
/// the same counting / recording outcome path as `convertResult` — the
/// `.perCall` index advances element-by-element, so an index→day mapping
/// still resolves the same way the serial walk did.
final class FakeConversionService: InstrumentConversionService, Sendable {
  /// A single conversion request, passed to the outcome closure.
  struct ConversionRequest: Sendable {
    let quantity: Decimal
    let from: Instrument
    let to: Instrument
    let date: Date
  }

  /// Decides the result of a conversion given the request and the
  /// zero-based index of the `convert` call (only calls that skip the
  /// same-instrument fast path advance the index). Returns a
  /// `ConversionResult` so a factory can produce `.knownZero` as well as
  /// `.value`.
  typealias Outcome = @Sendable (ConversionRequest, Int) -> Result<ConversionResult, any Error>

  private struct MutableState {
    var callCount = 0
    var convertAmountCallCount = 0
    var recordedCalls: [RecordingConversionServiceCall] = []
    var invalidatedInstruments: [Instrument] = []
    var recordedBatches: [[BatchConversionRequest]] = []
    var rateContinuation: AsyncStream<Void>.Continuation?
  }

  private let outcome: Outcome
  private let state = OSAllocatedUnfairLock(initialState: MutableState())
  /// Runtime-togglable failing-instrument set. Held in its own lock so the
  /// `.failingInstruments` outcome closure can read it (the closure is built
  /// before the instance exists, so it captures this box, not `self`).
  private let failingBox: OSAllocatedUnfairLock<Set<String>>

  /// - Parameters:
  ///   - failingInstrumentIds: Initial runtime-togglable failing set,
  ///     read by `.failingInstruments(_:)`. Other factories ignore it.
  ///   - outcome: The behaviour closure. Prefer a static factory.
  init(failingInstrumentIds: Set<String> = [], outcome: @escaping Outcome) {
    self.outcome = outcome
    self.failingBox = OSAllocatedUnfairLock(initialState: failingInstrumentIds)
  }

  /// Designated init used by `.failingInstruments(_:)` so the outcome
  /// closure and the instance share the same failing-set box. Internal so
  /// the factory extension in `FakeConversionService+Factories.swift` can
  /// reach it.
  init(
    failingBox: OSAllocatedUnfairLock<Set<String>>, outcome: @escaping Outcome
  ) {
    self.outcome = outcome
    self.failingBox = failingBox
  }

  // MARK: - Recording accessors

  /// Number of `convert` calls that reached the outcome closure (i.e.
  /// excluding same-instrument fast-path returns). Mirrors
  /// `ThrowingCountingConversionService.calls`.
  var callCount: Int { state.withLock { $0.callCount } }

  /// Number of `convertAmount` calls, including same-instrument early
  /// returns. Mirrors `CountingConversionService.convertAmountCallCount`.
  var convertAmountCallCount: Int { state.withLock { $0.convertAmountCallCount } }

  /// Every `convert(_:from:to:on:)` call, in order — including
  /// same-instrument no-ops that take the fast path. Mirrors
  /// `RecordingConversionService.calls`, which never short-circuited.
  var recordedCalls: [RecordingConversionServiceCall] {
    state.withLock { $0.recordedCalls }
  }

  /// Every instrument passed to `invalidateCache(for:)`, in order, with no
  /// dedup. Mirrors `RecordingConversionService.invalidatedInstruments`.
  var invalidatedInstruments: [Instrument] {
    state.withLock { $0.invalidatedInstruments }
  }

  /// Every `convertResultBatch(_:)` request set, in order. Lets batch-era
  /// tests assert the batch the daily-balance walk issued is one flat call
  /// of the expected size rather than N serial `convertResult` hops — e.g.
  /// `recordedBatches.last?.count == N`.
  var recordedBatches: [[BatchConversionRequest]] {
    state.withLock { $0.recordedBatches }
  }

  /// The current runtime failing-instrument set (for `.failingInstruments`).
  var failingInstrumentIds: Set<String> { failingBox.withLock { $0 } }

  // MARK: - Runtime control

  /// Replace the runtime failing-instrument set. Mirrors
  /// `FailingConversionService.setFailing(_:)`.
  func setFailing(_ ids: Set<String>) {
    failingBox.withLock { $0 = ids }
  }

  /// Push a non-initial rate tick (simulating a warm cache write landing).
  /// Mirrors `StubConversionService.emitRate()`.
  func emitRate() {
    let continuation = state.withLock { $0.rateContinuation }
    continuation?.yield(())
  }

  // MARK: - InstrumentConversionService

  /// Advance the counter, record the call, and invoke the outcome closure
  /// exactly once. Shared by `convert` and `convertResult` so both paths
  /// count and record identically — mirroring the old doubles, whose
  /// `convertResult` routed through `convert`. Same-instrument calls are
  /// handled by the callers before reaching here.
  private func runOutcome(
    _ request: ConversionRequest
  ) -> Result<ConversionResult, any Error> {
    let index = state.withLock { mutable -> Int in
      let current = mutable.callCount
      mutable.callCount += 1
      mutable.recordedCalls.append(
        RecordingConversionServiceCall(
          quantity: request.quantity, from: request.from, to: request.to,
          date: request.date))
      return current
    }
    return outcome(request, index)
  }

  func convert(
    _ quantity: Decimal, from: Instrument, to: Instrument, on date: Date
  ) async throws -> Decimal {
    if from.id == to.id {
      // Record the same-instrument call (mirroring `RecordingConversionService`,
      // which never short-circuited) so `recordedCalls` captures it, but do
      // NOT advance `callCount` or invoke the outcome closure — the fast path
      // must stay invisible to the rate-logic counters that the
      // `ThrowingCounting`-derived `callCount` assertions rely on.
      state.withLock {
        $0.recordedCalls.append(
          RecordingConversionServiceCall(
            quantity: quantity, from: from, to: to, date: date))
      }
      return quantity
    }
    let request = ConversionRequest(quantity: quantity, from: from, to: to, date: date)
    switch runOutcome(request) {
    case .success(let result):
      switch result {
      case .value(let amount):
        return amount.quantity
      case .knownZero:
        // `convert` returns a raw quantity and cannot express
        // `.knownZero`; surface it as the matching error so the
        // `convert` / `convertAmount` path stays distinct from
        // `convertResult` (mirrors `FixedConversionService`).
        throw FakeConversionError.knownZeroSource(instrumentId: from.id)
      }
    case .failure(let error):
      throw error
    }
  }

  func convertAmount(
    _ amount: InstrumentAmount, to instrument: Instrument, on date: Date
  ) async throws -> InstrumentAmount {
    state.withLock { $0.convertAmountCallCount += 1 }
    guard amount.instrument != instrument else { return amount }
    let converted = try await convert(
      amount.quantity, from: amount.instrument, to: instrument, on: date)
    return InstrumentAmount(quantity: converted, instrument: instrument)
  }

  func convertResult(
    _ amount: InstrumentAmount, to instrument: Instrument, on date: Date
  ) async throws -> ConversionResult {
    if amount.instrument == instrument { return .value(amount) }
    let request = ConversionRequest(
      quantity: amount.quantity, from: amount.instrument, to: instrument, date: date)
    // Invoke the outcome through the same counting / recording path as
    // `convert` (the old doubles routed `convertResult` → `convertAmount`
    // → `convert`, so `callCount` advances and the call is recorded for
    // failures and known-zeros too). The differences from `convert`:
    //   - `.knownZero` is surfaced as `.knownZero` here, not thrown.
    //   - the `.value` path also bumps `convertAmountCallCount`, because the
    //     old doubles reached `.value` via `convertAmount` (which counts).
    //     `.knownZero` returned before `convertAmount` in the old
    //     `FixedConversionService`, so it does NOT bump that counter.
    switch runOutcome(request) {
    case .success(let result):
      switch result {
      case .value(let converted):
        state.withLock { $0.convertAmountCallCount += 1 }
        return .value(converted)
      case .knownZero(let targetInstrument):
        return .knownZero(targetInstrument: targetInstrument)
      }
    case .failure(let error):
      throw error
    }
  }

  /// Batch override: records the request set (so tests can assert the walk
  /// issues ONE flat batch) and resolves each element through the same
  /// counting / recording outcome path as `convertResult`. Same-instrument
  /// requests take the fast path (`.value`, no outcome closure, no counter
  /// advance), exactly mirroring `convertResult`, so the outcome closure's
  /// zero-based index advances only across non-fast-path elements — keeping
  /// the `.perCall` index→day mapping the daily-balance walk relies on.
  ///
  /// A `.failure` from the outcome closure surfaces as `.failure(error)`
  /// per element, EXCEPT a `CancellationError`, which is rethrown so a
  /// cancelled batch never returns partial outcomes (matching the default
  /// implementation and the production override).
  func convertResultBatch(
    _ requests: [BatchConversionRequest]
  ) async throws -> [BatchConversionOutcome] {
    state.withLock { $0.recordedBatches.append(requests) }
    var outcomes: [BatchConversionOutcome] = []
    outcomes.reserveCapacity(requests.count)
    for request in requests {
      try Task.checkCancellation()
      if request.amount.instrument == request.target {
        outcomes.append(.value(request.amount))
        continue
      }
      let conversionRequest = ConversionRequest(
        quantity: request.amount.quantity, from: request.amount.instrument,
        to: request.target, date: request.date)
      switch runOutcome(conversionRequest) {
      case .success(.value(let converted)):
        outcomes.append(.value(converted))
      case .success(.knownZero(let targetInstrument)):
        outcomes.append(.knownZero(targetInstrument: targetInstrument))
      case .failure(let error):
        if error is CancellationError { throw CancellationError() }
        outcomes.append(.failure(error))
      }
    }
    return outcomes
  }

  func invalidateCache(for instrument: Instrument) async {
    state.withLock { $0.invalidatedInstruments.append(instrument) }
  }

  func observeRates() -> AsyncStream<Void> {
    let pair = AsyncStream<Void>.makeStream()
    state.withLock { $0.rateContinuation = pair.continuation }
    pair.continuation.yield(())  // initial on-subscribe tick
    return pair.stream
  }

  func observeErrors() -> AsyncStream<any Error> {
    AsyncStream { $0.finish() }
  }
}
