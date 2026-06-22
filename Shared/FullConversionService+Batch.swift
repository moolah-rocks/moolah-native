// Batch conversion override for `FullConversionService`.

import Foundation

extension FullConversionService {
  /// Optimised batch override:
  ///
  /// 1. Classifies each request via `convertResultDecision` — same-instrument
  ///    `.value` and crypto `.knownZero` resolve with no key (crypto status is
  ///    a cached metadata point-lookup through the `PriceSource` resolver).
  /// 2. Collects the distinct `RateCacheKey`s of the remaining
  ///    `.convert` requests, resolves the cache misses concurrently through
  ///    a bounded (≤16 in-flight) throwing task group over `computeUnitFactor`
  ///    (per-key errors captured; only cancellation aborts the group), and
  ///    folds the successes into `rateCache`.
  /// 3. Maps every request to its outcome in order, applying the resolved
  ///    factor as `(quantity * multiplier) / divisor` — the exact same math
  ///    as `convert(_:from:to:on:)`.
  ///
  /// `beforeFirstTrade` for a `.priced` crypto request surfaces as a captured
  /// per-key error, which maps to `.knownZero` (mirroring `convertResult`);
  /// every other captured error maps to `.failure`.
  func convertResultBatch(
    _ requests: [BatchConversionRequest]
  ) async throws -> [BatchConversionOutcome] {
    // Cancellation is task-wide: bail before any work if already cancelled
    // (the task group below also surfaces a mid-flight cancellation).
    try Task.checkCancellation()

    // Classify each request once, in order, computing the `RateCacheKey`
    // (and its resolution context) exactly once per `.convert` request so
    // `Date()` is consulted a single time — a second `keyContext(...)` in
    // the mapping pass could read a different `Date()` and alias a future
    // request onto the wrong UTC-day bucket. Collect the distinct
    // cache-miss contexts so each key is resolved at most once.
    var plans: [RequestPlan] = []
    plans.reserveCapacity(requests.count)
    var missingContexts: [RateCacheKey: KeyContext] = [:]
    for request in requests {
      let decision = await convertResultDecision(request.amount, to: request.target)
      switch decision {
      case .value, .knownZero:
        plans.append(RequestPlan(decision: decision, context: nil))
      case .convert:
        let context = keyContext(
          from: request.amount.instrument, to: request.target, on: request.date)
        plans.append(RequestPlan(decision: decision, context: context))
        if rateCache[context.key] == nil {
          missingContexts[context.key] = context
        }
      }
    }

    // Resolve distinct cache-miss keys concurrently; capture per-key
    // outcomes. Only cancellation aborts the group. Fold successes into
    // the shared memo so later calls hit the cache.
    let resolved = try await resolveMissingKeys(Array(missingContexts.values))
    for (key, result) in resolved {
      if case .success(let factor) = result {
        rateCache[key] = factor
      }
    }

    // Map every request to its outcome in order, reusing each request's
    // already-computed key context.
    return zip(requests, plans).map { request, plan in
      mapOutcome(request: request, plan: plan, resolved: resolved)
    }
  }

  /// One classified request: its `convertResultDecision` plus, for a
  /// `.convert`, the `KeyContext` computed once during classification and
  /// threaded through to the mapping pass so `Date()` (via `keyContext`) is
  /// consulted exactly once per request. `context` is `nil` for `.value` /
  /// `.knownZero` decisions, which need no key.
  private struct RequestPlan: Sendable {
    let decision: ConvertResultDecision
    let context: KeyContext?
  }

  /// A cache-miss key paired with the inputs needed to resolve it. The
  /// `key` is the `(fromId, toId, utc-day)` memo bucket; `source` /
  /// `target` / `effectiveDate` reproduce exactly what `unitFactor` /
  /// `convert` pass to `computeUnitFactor` (the cap-to-yesterday is applied
  /// upstream in `keyContext`).
  ///
  /// `Sendable` because it is captured into `withThrowingTaskGroup` child
  /// tasks by `resolveMissingKeys`.
  private struct KeyContext: Sendable {
    let key: RateCacheKey
    let source: Instrument
    let target: Instrument
    let effectiveDate: Date
  }

  /// Builds the `(fromId, toId, utc-day)` memo bucket plus the resolution
  /// context for a single conversion, capping a future date to today
  /// exactly as `convert(_:from:to:on:)` does (Rule 7) so the batch path
  /// and the per-call path agree on both the key and the resolved factor.
  private func keyContext(
    from source: Instrument, to target: Instrument, on date: Date
  ) -> KeyContext {
    let effectiveDate = min(date, Date())
    let key = RateCacheKey(
      fromId: source.id,
      toId: target.id,
      day: calendar.startOfDay(for: effectiveDate)
    )
    return KeyContext(
      key: key, source: source, target: target, effectiveDate: effectiveDate)
  }

  /// Resolves each distinct cache-miss key through `computeUnitFactor`,
  /// bounded to ≤16 in-flight tasks. Per-key errors are captured into the
  /// returned map; a `CancellationError` propagates out of the group and
  /// aborts the whole batch.
  private func resolveMissingKeys(
    _ contexts: [KeyContext]
  ) async throws -> [RateCacheKey: Result<UnitFactor, any Error>] {
    guard !contexts.isEmpty else { return [:] }
    return try await withThrowingTaskGroup(
      of: (RateCacheKey, Result<UnitFactor, any Error>).self
    ) { group in
      var resolved: [RateCacheKey: Result<UnitFactor, any Error>] = [:]
      resolved.reserveCapacity(contexts.count)
      var nextIndex = 0
      let maxInFlight = min(16, contexts.count)

      // Prime the window.
      while nextIndex < maxInFlight {
        let context = contexts[nextIndex]
        nextIndex += 1
        group.addTask { try await self.resolveKey(context) }
      }

      // Drain one, enqueue the next — keeping ≤16 tasks in flight.
      while let (key, result) = try await group.next() {
        resolved[key] = result
        if nextIndex < contexts.count {
          let context = contexts[nextIndex]
          nextIndex += 1
          group.addTask { try await self.resolveKey(context) }
        }
      }
      return resolved
    }
  }

  /// Resolves a single cache-miss key to its factor or a captured
  /// per-element error. A `CancellationError` is **rethrown** (not
  /// captured) so it propagates out of `withThrowingTaskGroup` and aborts
  /// the whole batch — cancellation is task-wide, never a per-element
  /// `.failure`. Every other error is captured.
  private func resolveKey(
    _ context: KeyContext
  ) async throws -> (RateCacheKey, Result<UnitFactor, any Error>) {
    do {
      let factor = try await computeUnitFactor(
        from: context.source, to: context.target, on: context.effectiveDate)
      return (context.key, .success(factor))
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return (context.key, .failure(error))
    }
  }

  /// Synchronously folds one classified request into its outcome using the
  /// resolved key map (or the existing `rateCache`). Reuses the
  /// `KeyContext` computed once during classification (threaded through
  /// `plan`) rather than recomputing it — so `Date()` is consulted exactly
  /// once per request. `beforeFirstTrade` maps to `.knownZero`; every other
  /// resolution error maps to `.failure`.
  private func mapOutcome(
    request: BatchConversionRequest,
    plan: RequestPlan,
    resolved: [RateCacheKey: Result<UnitFactor, any Error>]
  ) -> BatchConversionOutcome {
    switch plan.decision {
    case .value(let amount):
      return .value(amount)
    case .knownZero:
      return .knownZero(targetInstrument: request.target)
    case .convert:
      // `.convert` always carries its key context from classification.
      guard let context = plan.context else {
        return .failure(
          ConversionError.noProviderMapping(instrumentId: request.amount.instrument.id))
      }
      let factor: UnitFactor
      if let cached = rateCache[context.key] {
        factor = cached
      } else {
        switch resolved[context.key] {
        case .success(let resolvedFactor):
          factor = resolvedFactor
        case .failure(CryptoPriceError.beforeFirstTrade):
          return .knownZero(targetInstrument: request.target)
        case .failure(let error):
          return .failure(error)
        case .none:
          // Unreachable: every `.convert` miss key is in `resolved`.
          return .failure(
            ConversionError.noProviderMapping(instrumentId: request.amount.instrument.id))
        }
      }
      let quantity = (request.amount.quantity * factor.multiplier) / factor.divisor
      return .value(InstrumentAmount(quantity: quantity, instrument: request.target))
    }
  }
}
