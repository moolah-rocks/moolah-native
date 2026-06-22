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
  /// closure and the instance share the same failing-set box.
  private init(
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

/// Surfaces in `FakeConversionService` for the various failure / known-zero
/// scenarios the consolidated doubles modelled.
enum FakeConversionError: Error, Equatable {
  /// A `.knownZero` source reached `convert` / `convertAmount` rather than
  /// `convertResult`. Mirrors `FixedConversionError.knownZeroSource` and the
  /// production "no provider mapping" failure for `.unpriced` / `.spam`.
  case knownZeroSource(instrumentId: String)
  /// Sentinel for `.alwaysThrows` — proves a conversion path is NOT taken.
  /// Mirrors `ThrowingConversionService.Invoked`.
  case invoked
  /// A requested conversion date is in the failing set. Mirrors
  /// `DateFailingConversionError.unavailable`.
  case dateUnavailable(date: Date)
  /// Either side of a conversion is in the runtime failing set. Mirrors
  /// `FailingConversionError.unavailable`.
  case instrumentUnavailable(instrumentId: String)
}

// MARK: - Factories

extension FakeConversionService {
  /// Pass-through 1:1 on every call. Replaces `StubConversionService` and
  /// `RecordingConversionService`.
  static var passthrough: FakeConversionService {
    FakeConversionService { request, _ in
      .success(.value(InstrumentAmount(quantity: request.quantity, instrument: request.to)))
    }
  }

  /// Fixed rates keyed by source instrument id, 1:1 fallback when no rate
  /// is present. Source ids in `knownZero` resolve to `.knownZero` from
  /// `convertResult` (and throw `FakeConversionError.knownZeroSource` from
  /// `convert` / `convertAmount`). Replaces `FixedConversionService`.
  static func fixedRates(
    _ rates: [String: Decimal], knownZero: Set<String> = []
  ) -> FakeConversionService {
    FakeConversionService { request, _ in
      if knownZero.contains(request.from.id) {
        return .success(.knownZero(targetInstrument: request.to))
      }
      let rate = rates[request.from.id] ?? 1
      return .success(
        .value(InstrumentAmount(quantity: request.quantity * rate, instrument: request.to)))
    }
  }

  /// Date-keyed rates with "most recent date <= requested" lookup, 1:1
  /// fallback. Replaces `DateBasedFixedConversionService`.
  static func dateRates(_ rates: [Date: [String: Decimal]]) -> FakeConversionService {
    dateRates(rates, failingDates: [])
  }

  /// Date-keyed rates as `dateRates(_:)`, but throws
  /// `FakeConversionError.dateUnavailable` when the requested date is in
  /// `failingDates`. Replaces `DateFailingConversionService`.
  static func dateRates(
    _ rates: [Date: [String: Decimal]], failingDates: Set<Date>
  ) -> FakeConversionService {
    let sortedDates = rates.keys.sorted(by: >)
    return FakeConversionService { request, _ in
      if failingDates.contains(request.date) {
        return .failure(FakeConversionError.dateUnavailable(date: request.date))
      }
      let asOf = sortedDates.first { $0 <= request.date }.flatMap { rates[$0] } ?? [:]
      let rate = asOf[request.from.id] ?? 1
      return .success(
        .value(InstrumentAmount(quantity: request.quantity * rate, instrument: request.to)))
    }
  }

  /// Fixed rates keyed by source instrument id, but throws
  /// `FakeConversionError.instrumentUnavailable` when either side of the
  /// conversion is in the runtime failing set. Toggle the set at runtime
  /// with `setFailing(_:)`. Replaces `FailingConversionService`.
  static func failingInstruments(
    _ failingInstrumentIds: Set<String> = [], rates: [String: Decimal] = [:]
  ) -> FakeConversionService {
    let failingBox = OSAllocatedUnfairLock(initialState: failingInstrumentIds)
    return FakeConversionService(failingBox: failingBox) { request, _ in
      let failing = failingBox.withLock { $0 }
      if failing.contains(request.from.id) {
        return .failure(FakeConversionError.instrumentUnavailable(instrumentId: request.from.id))
      }
      if failing.contains(request.to.id) {
        return .failure(FakeConversionError.instrumentUnavailable(instrumentId: request.to.id))
      }
      let rate = rates[request.from.id] ?? 1
      return .success(
        .value(InstrumentAmount(quantity: request.quantity * rate, instrument: request.to)))
    }
  }

  /// Always throws `FakeConversionError.invoked` from every conversion that
  /// reaches the outcome closure (a sentinel proving a path is NOT taken).
  /// Replaces `ThrowingConversionService`.
  static var alwaysThrows: FakeConversionService {
    FakeConversionService { _, _ in .failure(FakeConversionError.invoked) }
  }

  /// Per-call-index outcome: the closure receives the zero-based `convert`
  /// call index and returns a raw `Decimal` result. Replaces
  /// `ThrowingCountingConversionService`.
  static func perCall(
    _ outcome: @escaping @Sendable (Int) -> Result<Decimal, any Error>
  ) -> FakeConversionService {
    FakeConversionService { request, index in
      outcome(index).map {
        .value(InstrumentAmount(quantity: $0, instrument: request.to))
      }
    }
  }
}
