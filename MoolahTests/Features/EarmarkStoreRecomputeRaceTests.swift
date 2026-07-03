import Foundation
import Testing

@testable import Moolah

/// Regression for the EarmarkStore twin of issue #1209. A conversion
/// recompute reads the `earmarks` snapshot at its start, then suspends in the
/// conversion service. Both paths that suspend under conversion —
/// `runConversionAttempt` and the instrument-registry refresh — capture
/// `snapshotGeneration` before suspending and drop their work if a fresher
/// authoritative snapshot has landed in the interim, so the stale recompute
/// cannot publish its now-outdated balances over the fresh ones. Without the
/// guard, a startup rate-tick pass over the empty initial earmarks publishes
/// *after* the real recompute and blanks the sidebar until the next retry.
@Suite("EarmarkStore -- recompute race (#1209 twin)")
@MainActor
struct EarmarkStoreRecomputeRaceTests {
  @Test
  func staleRecomputeDoesNotClobberFresherSnapshot() async throws {
    let aud = Instrument.AUD
    let accountId = UUID()
    let earmark = Earmark(name: "Holiday", instrument: aud)

    let (backend, database) = try TestBackend.create()
    TestBackend.seed(
      accounts: [Account(id: accountId, name: "Test", type: .bank, instrument: aud)],
      in: database)
    TestBackend.seed(earmarks: [earmark], in: database)
    TestBackend.seed(
      transactions: [
        Transaction(
          date: Date(),
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: aud, quantity: Decimal(100),
              type: .income, earmarkId: earmark.id)
          ])
      ], in: database)

    let conversion = GatingConversionService()
    let store = EarmarkStore(
      repository: backend.earmarks,
      conversionService: conversion,
      targetInstrument: aud,
      retryDelay: .seconds(60))

    // The initial authoritative snapshot lands: balance 100.
    await expectEventually("initial earmark balance settles") {
      store.convertedBalances[earmark.id]?.quantity == 100
    }

    // Start a recompute that reads the current (100) earmarks snapshot and
    // suspends inside `convertResultBatch`, holding its stale result.
    conversion.armGate()
    let staleRecompute = Task { await store.recomputeConvertedTotals() }
    await conversion.waitUntilGateReached()

    // A fresher authoritative snapshot lands while the stale recompute is
    // suspended: same earmark, balance 999. This mirrors what
    // `applyEarmarksSnapshot` does — bump the generation, then apply.
    let freshEarmark = Earmark(
      id: earmark.id, name: earmark.name, instrument: aud,
      positions: [Position(instrument: aud, quantity: Decimal(999))])
    store.bumpSnapshotGeneration()
    await store.apply(earmarks: [freshEarmark])
    let freshBalance = try #require(
      store.convertedBalances[earmark.id], "fresh balance must be present")
    #expect(freshBalance.quantity == 999)

    // Release the stale recompute. Its now-outdated publish must be dropped,
    // not clobber the fresh 999 balance back to 100.
    conversion.releaseGate()
    await staleRecompute.value

    let settledBalance = try #require(
      store.convertedBalances[earmark.id], "balance must survive the stale publish")
    #expect(settledBalance.quantity == 999)
  }

  /// A superseded stale recompute must not cancel the retry loop that a
  /// fresher, *failing* pass started. The stale pass "succeeds" over old data,
  /// but reporting that success would cancel the retry the failing earmark
  /// needs, leaving it blank forever.
  @Test
  func staleRecomputeDoesNotCancelFreshRetry() async throws {
    let aud = Instrument.AUD
    let usd = Instrument.USD
    let accountId = UUID()
    let earmark = Earmark(name: "Holiday", instrument: aud)

    let (backend, database) = try TestBackend.create()
    TestBackend.seed(
      accounts: [Account(id: accountId, name: "Test", type: .bank, instrument: aud)],
      in: database)
    TestBackend.seed(earmarks: [earmark], in: database)
    TestBackend.seed(
      transactions: [
        Transaction(
          date: Date(),
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: aud, quantity: Decimal(100),
              type: .income, earmarkId: earmark.id)
          ])
      ], in: database)

    let conversion = GatingConversionService()
    let store = EarmarkStore(
      repository: backend.earmarks,
      conversionService: conversion,
      targetInstrument: aud,
      retryDelay: .milliseconds(200))

    await expectEventually("initial earmark balance settles") {
      store.convertedBalances[earmark.id]?.quantity == 100
    }

    // Hold a stale recompute suspended over the current (AUD-only, cleanly
    // converting) earmarks.
    conversion.armGate()
    let staleRecompute = Task { await store.recomputeConvertedTotals() }
    await conversion.waitUntilGateReached()

    // A fresher authoritative snapshot lands whose earmark now needs a USD
    // conversion that fails, so the fresh pass fails and starts the retry loop.
    conversion.setFailing([usd.id])
    let freshEarmark = Earmark(
      id: earmark.id, name: earmark.name, instrument: aud,
      positions: [Position(instrument: usd, quantity: Decimal(50))])
    store.bumpSnapshotGeneration()
    await store.apply(earmarks: [freshEarmark])
    #expect(store.convertedBalances[earmark.id] == nil)

    // Recover the service, then release the stale pass. Its stale "success"
    // must not cancel the fresh pass's retry.
    conversion.setFailing([])
    conversion.releaseGate()
    await staleRecompute.value

    // The retry loop survives and repopulates the balance once it fires.
    await expectEventually("retry repopulates the failing earmark's balance") {
      store.convertedBalances[earmark.id]?.quantity == 50
    }
  }
}
