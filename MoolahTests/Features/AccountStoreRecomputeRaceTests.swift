import Foundation
import Testing
import os

@testable import Moolah

/// Regression for #1209. A balance recompute reads the accounts snapshot at
/// its start, then suspends in the conversion service. If a *fresher*
/// authoritative accounts snapshot lands while it is suspended, the stale
/// recompute must not publish its now-outdated result over the fresh one.
///
/// This is the same "racing observation pass clobbers fresher state" class
/// that `applyInstrumentRegistryRefresh` already guards against with
/// `snapshotGeneration`; before the fix, `recomputeConvertedTotals` /
/// `publishSnapshot` had no such guard, so a startup rate-tick recompute
/// running over the empty initial accounts snapshot could publish *after*
/// the real accounts recompute and blank the sidebar until a 60s retry.
@Suite("AccountStore -- recompute race (#1209)")
@MainActor
struct AccountStoreRecomputeRaceTests {
  /// A conversion double whose `convertResultBatch` can be paused mid-call
  /// exactly once. Conversions are 1:1 passthrough; the gate is the only
  /// interesting behaviour. `observeRates()` deliberately emits no initial
  /// tick so the only recomputes are the ones the test drives explicitly.
  private final class GatingConversionService: InstrumentConversionService, @unchecked Sendable {
    private let armed = OSAllocatedUnfairLock(initialState: false)
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
    /// point that recompute has already captured its accounts snapshot.
    func waitUntilGateReached() async {
      var iterator = reached.makeAsyncIterator()
      _ = await iterator.next()
    }

    /// Releases the suspended `convertResultBatch` call.
    func releaseGate() { gateContinuation.yield(()) }

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
      return requests.map {
        .value(InstrumentAmount(quantity: $0.amount.quantity, instrument: $0.target))
      }
    }

    func convert(
      _ quantity: Decimal, from: Instrument, to: Instrument, on date: Date
    ) async throws -> Decimal { quantity }

    func convertAmount(
      _ amount: InstrumentAmount, to instrument: Instrument, on date: Date
    ) async throws -> InstrumentAmount {
      InstrumentAmount(quantity: amount.quantity, instrument: instrument)
    }

    func convertResult(
      _ amount: InstrumentAmount, to instrument: Instrument, on date: Date
    ) async throws -> ConversionResult {
      .value(InstrumentAmount(quantity: amount.quantity, instrument: instrument))
    }

    func invalidateCache(for instrument: Instrument) async {}
    func observeRates() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    func observeErrors() -> AsyncStream<any Error> { AsyncStream { $0.finish() } }
  }

  @Test
  func staleRecomputeDoesNotClobberFresherSnapshot() async throws {
    let aud = Instrument.AUD
    let account = Account(name: "AUD Bank", type: .bank, instrument: aud)

    let (backend, database) = try TestBackend.create()
    TestBackend.seed(accounts: [account], in: database)
    TestBackend.seed(
      transactions: [
        Transaction(
          date: Date(),
          legs: [
            TransactionLeg(
              accountId: account.id, instrument: aud,
              quantity: Decimal(100), type: .openingBalance)
          ])
      ], in: database)

    let conversion = GatingConversionService()
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: conversion,
      targetInstrument: aud,
      retryDelay: .seconds(60))

    // The initial authoritative snapshot lands: balance 100.
    await expectEventually("initial balance settles") {
      store.convertedBalances[account.id]?.quantity == 100
    }

    // Start a recompute that reads the current (100) accounts snapshot and
    // suspends inside `convertResultBatch`, holding its stale result.
    conversion.armGate()
    let staleRecompute = Task { await store.recomputeForRateTick() }
    await conversion.waitUntilGateReached()

    // A fresher authoritative snapshot lands while the stale recompute is
    // suspended: same account, balance 999. This mirrors what
    // `applyAccountsSnapshot` does — bump the generation, then apply.
    let freshAccount = Account(
      id: account.id, name: account.name, type: .bank, instrument: aud,
      positions: [Position(instrument: aud, quantity: Decimal(999))])
    store.bumpSnapshotGeneration()
    await store.apply(accounts: [freshAccount])
    let freshBalance = try #require(
      store.convertedBalances[account.id], "fresh balance must be present")
    #expect(freshBalance.quantity == 999)

    // Release the stale recompute. Its now-outdated publish must be dropped,
    // not clobber the fresh 999 balance back to 100.
    conversion.releaseGate()
    await staleRecompute.value

    let settledBalance = try #require(
      store.convertedBalances[account.id], "balance must survive the stale publish")
    #expect(settledBalance.quantity == 999)
  }
}
