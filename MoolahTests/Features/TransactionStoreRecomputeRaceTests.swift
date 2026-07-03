import Foundation
import Testing

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

    let conversion = GatingConversionService()
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
