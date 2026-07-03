import Foundation
import Testing

@testable import Moolah

/// Test-only protocol for awaiting store observation emissions.
///
/// Production stores do NOT conform to this in the production target;
/// the conformance is added in this file (test target only) so the
/// "I just applied an emission" tick stream stays out of the live
/// `@Observable` store.
@MainActor
protocol TestableStoreObservation: AnyObject, Sendable {
  associatedtype State

  var observationTicks: AsyncStream<Void> { get }

  var snapshot: State { get }
}

/// Thrown by the `waitForFirstEmission` / `waitForNextEmission` helpers
/// when the underlying store does not emit within the deadline.
struct StoreEmissionTimeoutError {
  let storeType: String
  let predicate: String?
}

extension StoreEmissionTimeoutError: Error {}

extension StoreEmissionTimeoutError: CustomStringConvertible {
  var description: String {
    if let predicate {
      return "Timed out waiting for \(storeType) emission matching \(predicate)"
    }
    return "Timed out waiting for first \(storeType) emission"
  }
}

extension TestableStoreObservation {
  /// Awaits the next emission from `observationTicks`. Throws
  /// `StoreEmissionTimeoutError` if no emission occurs within
  /// `timeout`. A finished stream (e.g. because `stopObserving()` has
  /// already cancelled the observation) counts as a timeout, not a
  /// completion — `didEmitWithin` relies on this distinction to assert
  /// the absence of post-cancellation emissions.
  ///
  /// The default is deliberately generous (10s). A match-wait should never
  /// fail because a loaded CI runner was slow — short timeouts are a leading
  /// source of CI flakes. The helper returns the instant the emission lands,
  /// so the large cap only buys headroom, never latency. Pass a short
  /// `timeout` only to assert the *absence* of an emission (see
  /// `didEmitWithin`).
  func waitForFirstEmission(timeout: Duration = .seconds(10)) async throws {
    let ticks = observationTicks
    try await withEmissionTimeout(
      timeout,
      storeType: "\(Self.self)",
      predicate: nil
    ) {
      var iterator = ticks.makeAsyncIterator()
      if await iterator.next() != nil {
        return  // got a real tick
      }
      // Stream finished without yielding — block long enough that the
      // timeout-task in `withEmissionTimeout` always wins, so the
      // caller observes "no emission" rather than a false-positive
      // completion. 5 minutes is far past every per-test timeout in
      // the suite (default 10s) but tight enough that a runaway
      // cancellation doesn't hang CI for an hour.
      try? await Task.sleep(for: .seconds(300))
    }
  }

  /// Awaits emissions until `predicate(snapshot)` returns true. Throws
  /// `StoreEmissionTimeoutError` if no matching emission arrives within
  /// `timeout`. The predicate runs on `@MainActor` (it reads
  /// `@MainActor`-isolated store state); each tick body hops to
  /// `@MainActor` to read the snapshot before evaluating.
  ///
  /// The default is deliberately generous (10s) — see `waitForFirstEmission`.
  /// Callers rarely need to override `timeout`; a match-wait wants headroom,
  /// not a short cap. Override only to assert absence of emission — see
  /// `didEmitWithin`.
  func waitForNextEmission(
    matching predicate: @MainActor @Sendable @escaping (State) -> Bool,
    description: String = "<predicate>",
    timeout: Duration = .seconds(10)
  ) async throws {
    let ticks = observationTicks
    // The body must be `@Sendable` for `withTaskGroup`; we cannot
    // capture `self` (the protocol existential is not `Sendable`).
    // Capture a `@Sendable` closure that reads the snapshot on
    // `@MainActor` instead — this works because every concrete
    // conforming type is itself `@MainActor` and the `snapshot`
    // accessor is therefore safe to call from a MainActor hop.
    let evaluate: @MainActor @Sendable () -> Bool = { [self] in
      predicate(self.snapshot)
    }
    try await withEmissionTimeout(
      timeout,
      storeType: "\(Self.self)",
      predicate: description
    ) {
      // Fast path: the predicate may already be true (e.g. the store
      // applied the awaited state before this helper was called).
      if await evaluate() { return }
      // Otherwise race two independent satisfiers, bounded by
      // `withEmissionTimeout`'s deadline (see `awaitPredicate`): a
      // tick-driven re-check AND a concurrent predicate poll. The poll is
      // load-bearing, not just a fallback — a reactive store assigns its
      // published state BEFORE it yields the observation tick, and the tick
      // fires only after a recompute that can suspend arbitrarily in the
      // conversion layer. Keying solely off the tick let this helper time out
      // while the awaited state was already present (the flaky
      // `EarmarkStoreApplyDeltaTests` emission-wait). Polling observes the
      // state directly; the tick path keeps the common case latency-free.
      await awaitPredicate(ticks: ticks, evaluate: evaluate)
    }
  }

  /// Returns `true` if an emission arrived within `timeout`, otherwise
  /// `false`. Used to assert *absence* of emission (e.g. after
  /// `stopObserving()` cancels the stream).
  func didEmitWithin(timeout: Duration) async -> Bool {
    do {
      try await waitForFirstEmission(timeout: timeout)
      return true
    } catch {
      return false
    }
  }

  /// Drains any ticks already buffered in `observationTicks` so a
  /// subsequent `didEmitWithin(_:)` only sees ticks that arrive AFTER
  /// the call. Returns immediately when the buffer is empty.
  ///
  /// Required by tests that assert absence-of-emission semantics
  /// (e.g. "no emission after stopObserving()") because
  /// `AsyncStream`'s default buffering policy retains every previously
  /// yielded value, and a single `iterator.next()` would consume one
  /// of those instead of the post-action emission the test cares
  /// about.
  func drainPendingEmissions() async {
    let ticks = observationTicks
    while await waitForOneTick(in: ticks, timeout: .milliseconds(20)) {}
  }
}

/// Waits until `evaluate()` returns `true`, or until the surrounding task is
/// cancelled (the `withEmissionTimeout` deadline). Races two satisfiers so the
/// wait can never miss an already-true predicate:
///
///   1. **Tick-driven** — re-checks `evaluate()` on every observation tick, so
///      a matching emission is observed the instant it lands (latency-free
///      common case).
///   2. **Poll-driven** — re-checks `evaluate()` on a short interval, so state
///      a store assigns BEFORE it yields the corresponding tick is still
///      observed. Reactive stores set their published state, then yield the
///      test tick only AFTER a recompute that can suspend arbitrarily in the
///      conversion layer; a tick-only wait timed out while the awaited state
///      was already present.
///
/// The first child to observe the predicate ends the group; `cancelAll()` then
/// stops the other. AsyncStream's iterator is cancellation-aware (`next()`
/// returns `nil` on cancellation), so the group unwinds cleanly. File-scope so
/// it can run inside the `@Sendable` `withEmissionTimeout` body without
/// capturing `Self`.
private func awaitPredicate(
  ticks: AsyncStream<Void>,
  evaluate: @escaping @MainActor @Sendable () -> Bool
) async {
  await withTaskGroup(of: Void.self) { group in
    group.addTask {
      var iterator = ticks.makeAsyncIterator()
      while await iterator.next() != nil {
        if await evaluate() { return }
      }
    }
    group.addTask {
      while !Task.isCancelled {
        if await evaluate() { return }
        // Re-check after the `evaluate()` suspension before sleeping, so a
        // cancellation that lands in that window exits promptly.
        guard !Task.isCancelled else { return }
        try? await Task.sleep(for: .milliseconds(20))
      }
    }
    _ = await group.next()
    group.cancelAll()
  }
}

/// Awaits a single tick from `stream`, returning `true` if one arrived
/// within `timeout`, `false` otherwise. File-scope (rather than nested
/// in `TestableStoreObservation`) so it can be invoked from a
/// `@Sendable` body without capturing `Self`.
private func waitForOneTick(
  in stream: AsyncStream<Void>,
  timeout: Duration
) async -> Bool {
  let result = await withTaskGroup(of: RaceResult.self) { group -> RaceResult in
    group.addTask {
      var iterator = stream.makeAsyncIterator()
      if await iterator.next() != nil {
        return .completed
      }
      return .timedOut
    }
    group.addTask {
      try? await Task.sleep(for: timeout)
      return .timedOut
    }
    let first = await group.next() ?? .timedOut
    group.cancelAll()
    return first
  }
  return result == .completed
}

/// Hoisted to file scope so `withEmissionTimeout`'s nesting depth stays
/// at 1 (SwiftLint's `nesting` rule complains about depth-2 type
/// nesting).
private enum RaceResult: Sendable { case completed, timedOut }

/// Runs `body` with a deadline. Throws `StoreEmissionTimeoutError` if
/// `body` doesn't complete within `timeout`. Uses an enum to carry the
/// race result out of the `TaskGroup` so the throw is gated on the
/// timeout actually winning, not run unconditionally.
private func withEmissionTimeout(
  _ timeout: Duration,
  storeType: String,
  predicate: String?,
  body: @escaping @Sendable () async -> Void
) async throws {
  let result = await withTaskGroup(of: RaceResult.self) { group -> RaceResult in
    group.addTask {
      await body()
      return .completed
    }
    group.addTask {
      try? await Task.sleep(for: timeout)
      return .timedOut
    }
    let first = await group.next() ?? .timedOut
    group.cancelAll()
    return first
  }

  if result == .timedOut {
    throw StoreEmissionTimeoutError(storeType: storeType, predicate: predicate)
  }
}

// MARK: - Test target conformances

extension AccountStore: TestableStoreObservation {
  var observationTicks: AsyncStream<Void> { testObservationTickStream }
  /// Tests assert directly against published `@Observable` state; the
  /// snapshot is the store itself.
  var snapshot: AccountStore { self }
}

extension AccountGroupStore: TestableStoreObservation {
  var observationTicks: AsyncStream<Void> { testObservationTickStream }
  /// Tests assert directly against published `@Observable` state; the
  /// snapshot is the store itself.
  var snapshot: AccountGroupStore { self }
}

extension GroupUIStateStore: TestableStoreObservation {
  var observationTicks: AsyncStream<Void> { testObservationTickStream }
  /// Tests assert directly against published `@Observable` state; the
  /// snapshot is the store itself.
  var snapshot: GroupUIStateStore { self }
}

extension EarmarkStore: TestableStoreObservation {
  var observationTicks: AsyncStream<Void> { testObservationTickStream }
  /// Tests assert directly against published `@Observable` state; the
  /// snapshot is the store itself.
  var snapshot: EarmarkStore { self }
}

extension CategoryStore: TestableStoreObservation {
  var observationTicks: AsyncStream<Void> { testObservationTickStream }
  /// Tests assert directly against published `@Observable` state; the
  /// snapshot is the store itself.
  var snapshot: CategoryStore { self }
}

extension ImportRuleStore: TestableStoreObservation {
  var observationTicks: AsyncStream<Void> { testObservationTickStream }
  /// Tests assert directly against published `@Observable` state; the
  /// snapshot is the store itself.
  var snapshot: ImportRuleStore { self }
}

extension TransactionStore: TestableStoreObservation {
  var observationTicks: AsyncStream<Void> { testObservationTickStream }
  /// Tests assert directly against published `@Observable` state; the
  /// snapshot is the store itself.
  var snapshot: TransactionStore { self }
}

extension InvestmentStore: TestableStoreObservation {
  var observationTicks: AsyncStream<Void> { testObservationTickStream }
  /// Tests assert directly against published `@Observable` state; the
  /// snapshot is the store itself.
  var snapshot: InvestmentStore { self }
}
