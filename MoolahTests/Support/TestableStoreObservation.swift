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
struct StoreEmissionTimeoutError: Error, CustomStringConvertible {
  let storeType: String
  let predicate: String?
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
  func waitForFirstEmission(timeout: Duration = .seconds(2)) async throws {
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
      // Stream finished without yielding — block until the timeout
      // wins so the caller observes "no emission" rather than a
      // false-positive completion. A 1-hour sleep is well beyond any
      // sensible test timeout; the timeout-task in
      // `withEmissionTimeout` will cancel it.
      try? await Task.sleep(for: .seconds(3600))
    }
  }

  /// Awaits emissions until `predicate(snapshot)` returns true. Throws
  /// `StoreEmissionTimeoutError` if no matching emission arrives within
  /// `timeout`. The predicate runs on `@MainActor` (it reads
  /// `@MainActor`-isolated store state); each tick body hops to
  /// `@MainActor` to read the snapshot before evaluating.
  func waitForNextEmission(
    matching predicate: @MainActor @Sendable @escaping (State) -> Bool,
    description: String = "<predicate>",
    timeout: Duration = .seconds(2)
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
      var iterator = ticks.makeAsyncIterator()
      while await iterator.next() != nil {
        if await evaluate() { return }
      }
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
