import Foundation
import os

@testable import Moolah

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
