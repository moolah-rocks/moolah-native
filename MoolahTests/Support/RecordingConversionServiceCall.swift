import Foundation
import os

@testable import Moolah

/// One recorded call to a conversion double's `convert(_:from:to:on:)`.
/// Top-level so tests can construct, compare, and pattern-match values
/// without fully qualifying them through a service type. Recorded by
/// `RecordingConversionService` and `FakeConversionService`.
struct RecordingConversionServiceCall: Sendable, Equatable {
  let quantity: Decimal
  let from: Instrument
  let to: Instrument
  let date: Date
}

/// Async-safe collector for per-row failure-callback fan-out observed by
/// analysis-repository tests. Backed by `OSAllocatedUnfairLock` so the
/// `@Sendable` closure passed to a handler can append from whichever
/// isolation domain the helper resumes on without a data-race waiver.
final class FailureLog: Sendable {
  private let entries = OSAllocatedUnfairLock<[Int]>(initialState: [])

  func append(_ value: Int) {
    entries.withLock { $0.append(value) }
  }

  func snapshot() -> [Int] {
    entries.withLock { $0 }
  }
}

/// Async-safe collector for `(Error, Date)` failure tuples emitted by
/// `DailyBalancesHandlers.handleInvestmentValueFailure`. Used by tests that
/// need to assert which day surfaced through the per-day error callback (and
/// how many times). Backed by `OSAllocatedUnfairLock` for the same
/// `@Sendable`-closure-mutation reason as `FailureLog` — and exposes only
/// `append(_:_:)` and `snapshot()` so multi-field reads are atomic with
/// respect to a single lock acquisition (mirrors the `FailureLog` API shape).
///
/// `(Error, Date)` is `Sendable` because Swift's `Error` protocol inherits
/// from `Sendable` (Swift 5.7+), so the existential `any Error` is `Sendable`
/// and `OSAllocatedUnfairLock<[(Error, Date)]>` satisfies the conditional
/// `Sendable where State: Sendable` requirement.
final class InvestmentValueFailureLog: Sendable {
  private let entries = OSAllocatedUnfairLock<[(Error, Date)]>(initialState: [])

  func append(_ error: Error, _ date: Date) {
    entries.withLock { $0.append((error, date)) }
  }

  func snapshot() -> [(Error, Date)] {
    entries.withLock { $0 }
  }
}
