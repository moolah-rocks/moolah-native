import Foundation
import Testing
import os

@testable import Moolah

/// Regression for the InvestmentStore facet of #1209. `valuatePositions`
/// snapshots `positions` at its start, then suspends in the conversion layer
/// (`convertResultBatch`). If a fresher authoritative load supersedes it while
/// it is suspended — classically a background rate-tick valuation for the
/// previous account racing an account switch — the stale pass must not publish
/// its now-outdated valued positions / total over the switched-to account.
@Suite("InvestmentStore -- recompute race (#1209)")
@MainActor
struct InvestmentStoreRecomputeRaceTests {
  @Test
  func staleValuationDoesNotClobberFresherLoad() async throws {
    let aud = Instrument.AUD
    let usd = Instrument.USD
    let eur = Instrument.fiat(code: "EUR")

    let conversion = GatingBatchConversion()
    let (backend, _) = try TestBackend.create()
    let store = InvestmentStore(
      repository: backend.investments, conversionService: conversion)

    // Account A's positions are loaded (a USD position, cross-instrument to
    // AUD so the valuation issues a `convertResultBatch` the gate can catch).
    store.setPositions([Position(instrument: usd, quantity: Decimal(10))])

    // Start a rate-tick-style valuation over account A and hold it suspended.
    conversion.armGate()
    let staleValuation = Task { await store.valuatePositions(profileCurrency: aud, on: Date()) }
    await conversion.waitUntilGateReached()

    // A fresher authoritative load supersedes it: bump the generation (as
    // `loadAllData` does), swap in account B's position, and valuate it.
    store.bumpSnapshotGeneration()
    store.setPositions([Position(instrument: eur, quantity: Decimal(20))])
    await store.valuatePositions(profileCurrency: aud, on: Date())
    #expect(store.valuedPositions.map(\.instrument.id) == [eur.id])
    #expect(store.totalPortfolioValue == Decimal(20))

    // Release the stale valuation. Its account-A publish must be dropped, not
    // clobber account B's valued positions / total.
    conversion.releaseGate()
    await staleValuation.value

    #expect(store.valuedPositions.map(\.instrument.id) == [eur.id])
    #expect(store.totalPortfolioValue == Decimal(20))
  }
}

/// A conversion double whose `convertResultBatch` pauses once, so the test can
/// force a stale valuation to publish after a fresher one. 1:1 passthrough;
/// `observeRates()` emits no tick so the only valuations are the ones the test
/// drives. Kept file-local to avoid coupling to a shared test helper that is
/// not yet available in this module.
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
