import Foundation
import Testing
import os

@testable import Moolah

/// Regression for the TransactionStore facet of #1209. `recomputeBalances`
/// reads `lastSnapshotPage` at its start, then suspends in the conversion
/// layer (`convertResultBatch`). If a fresher snapshot lands while it is
/// suspended — a new emission or a filter change — the stale pass must not
/// publish its now-outdated running-balance rows over the fresher list (a
/// just-added transaction would vanish until the next tick).
@Suite("TransactionStore -- recompute race (#1209)")
@MainActor
struct TransactionStoreRecomputeRaceTests {
  @Test
  func staleRecomputeDoesNotClobberFresherSnapshot() async throws {
    let aud = Instrument.AUD
    let usd = Instrument.USD
    let accountId = UUID()
    // USD legs force a `convertResultBatch` (target AUD), so the gate fires.
    let txnA = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(accountId: accountId, instrument: usd, quantity: Decimal(10), type: .income)
      ])
    let txnB = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(accountId: accountId, instrument: usd, quantity: Decimal(20), type: .income)
      ])
    let pageA = TransactionPage(
      transactions: [txnA], targetInstrument: aud, priorBalance: nil, totalCount: 1)
    let pageB = TransactionPage(
      transactions: [txnB, txnA], targetInstrument: aud, priorBalance: nil, totalCount: 2)

    let conversion = GatingBatchConversion()
    let (backend, _) = try TestBackend.create()
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: conversion,
      targetInstrument: aud)

    // Establish the initial snapshot (one row) without touching the gate.
    store.setupForFilter(TransactionFilter(accountId: accountId))
    await store.applySnapshot(pageA, observedCount: 1, fetchMs: 0)
    #expect(store.transactions.count == 1)

    // Start a rate-tick recompute over the current (one-row) snapshot and
    // hold it suspended in the conversion layer.
    conversion.armGate()
    let staleRecompute = Task { await store.recomputeBalances(reason: .rateTick) }
    await conversion.waitUntilGateReached()

    // A fresher snapshot (two rows) lands while the stale recompute is
    // suspended and publishes its rows.
    await store.applySnapshot(pageB, observedCount: 2, fetchMs: 0)
    #expect(store.transactions.count == 2)

    // Release the stale recompute. Its one-row publish must be dropped, not
    // clobber the fresher two-row list.
    conversion.releaseGate()
    await staleRecompute.value

    #expect(store.transactions.count == 2)
    #expect(store.transactions.map(\.transaction.id) == [txnB.id, txnA.id])
  }
}

/// A conversion double whose `convertResultBatch` pauses once, so the test can
/// force a stale recompute to publish after a fresher one. 1:1 passthrough;
/// `observeRates()` emits no tick so the only recomputes are the ones the test
/// drives. (The `MoolahTests/Support/GatingConversionService` shared double
/// lands separately in #1211; kept file-local here to avoid cross-PR coupling.)
private final class GatingBatchConversion {
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

  func armGate() { armed.withLock { $0 = true } }

  func waitUntilGateReached() async {
    var iterator = reached.makeAsyncIterator()
    _ = await iterator.next()
  }

  func releaseGate() { gateContinuation.yield(()) }
}

extension GatingBatchConversion: InstrumentConversionService {
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

extension GatingBatchConversion: Sendable {}
