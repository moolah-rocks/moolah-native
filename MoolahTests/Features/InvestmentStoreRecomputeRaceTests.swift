import Foundation
import Testing

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

    let conversion = GatingConversionService()
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
