import Foundation
import Testing

@testable import Moolah

@Suite("EarmarkStore -- Partial Conversion Failures")
@MainActor
struct EarmarkStorePartialConversionTests {

  /// When one earmark's positions can't be converted to its own instrument,
  /// other earmarks whose conversions succeed still appear in
  /// `convertedBalances`. The aggregate `convertedTotalBalance` stays nil
  /// because we cannot accurately sum a set with a missing value.
  @Test
  func earmarkBalancePopulatesEvenWhenAnotherFails() async throws {
    let aud = Instrument.AUD
    let usd = Instrument.USD
    let eur = Instrument.fiat(code: "EUR")
    let accountId = UUID()
    let healthyEarmark = Earmark(name: "Holiday", instrument: aud)
    let mixedEarmark = Earmark(name: "Mixed", instrument: eur)

    let (backend, database) = try TestBackend.create()
    TestBackend.seed(
      accounts: [Account(id: accountId, name: "Test", type: .bank, instrument: aud)],
      in: database)
    TestBackend.seed(earmarks: [healthyEarmark, mixedEarmark], in: database)

    // Healthy earmark: AUD positions only.
    let healthyTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: Decimal(300),
          type: .income, earmarkId: healthyEarmark.id)
      ])
    // Mixed earmark: EUR + USD; USD → EUR conversion will fail.
    let mixedEurTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: eur, quantity: Decimal(100),
          type: .income, earmarkId: mixedEarmark.id)
      ])
    let mixedUsdTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: usd, quantity: Decimal(50),
          type: .income, earmarkId: mixedEarmark.id)
      ])
    TestBackend.seed(transactions: [healthyTx, mixedEurTx, mixedUsdTx], in: database)

    let conversion = FailingConversionService(failingInstrumentIds: ["USD"])
    let store = EarmarkStore(
      repository: backend.earmarks,
      conversionService: conversion,
      targetInstrument: aud,
      retryDelay: .seconds(60))

    // The reactive store publishes the partial-failure state on the
    // first emission: the healthy earmark's balance populates while the
    // mixed earmark (and therefore the aggregate total) stay nil. Poll the
    // full post-condition so a racing recompute can't slip a stale read in.
    await expectEventually(
      "healthy earmark settles while the failing earmark and total stay nil"
    ) {
      store.convertedBalance(for: healthyEarmark.id)?.quantity == 300
        && store.convertedBalance(for: mixedEarmark.id) == nil
        && store.convertedTotalBalance == nil
    }
  }

  /// After the conversion service recovers, a retry populates the
  /// failed earmark balance and the aggregate total.
  @Test
  func conversionFailuresAreRetriedAfterDelay() async throws {
    let aud = Instrument.AUD
    let eur = Instrument.fiat(code: "EUR")
    let accountId = UUID()
    let audEarmark = Earmark(name: "AUD", instrument: aud)
    let eurEarmark = Earmark(name: "EUR", instrument: eur)

    let (backend, database) = try TestBackend.create()
    TestBackend.seed(
      accounts: [Account(id: accountId, name: "Test", type: .bank, instrument: aud)],
      in: database)
    TestBackend.seed(earmarks: [audEarmark, eurEarmark], in: database)

    let audTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: Decimal(400),
          type: .income, earmarkId: audEarmark.id)
      ])
    let eurTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: eur, quantity: Decimal(200),
          type: .income, earmarkId: eurEarmark.id)
      ])
    TestBackend.seed(transactions: [audTx, eurTx], in: database)

    let conversion = FailingConversionService(failingInstrumentIds: ["EUR"])
    let store = EarmarkStore(
      repository: backend.earmarks,
      conversionService: conversion,
      targetInstrument: aud,
      retryDelay: .milliseconds(20))

    // Wait for the first conversion pass; since EUR fails we land in
    // the partial-failure state with a retry loop running in the
    // background.
    // Aggregate cannot be computed (EUR → AUD fails) while the AUD earmark
    // balance settles. Per-earmark balances are still displayed in their own
    // currency where no conversion is needed.
    await expectEventually(
      "AUD earmark settles while the EUR failure keeps the total nil"
    ) {
      store.convertedBalance(for: audEarmark.id)?.quantity == 400
        && store.convertedTotalBalance == nil
    }

    // Recover the conversion service and wait for the retry loop to
    // succeed — `waitForPendingConversions()` returns when the loop
    // terminates on the first successful attempt.
    await conversion.setFailing([])
    await store.waitForPendingConversions()

    // 400 AUD + 200 EUR (1:1 fallback) = 600 AUD
    await expectEventually("recovered retry populates per-earmark balances and the total") {
      store.convertedTotalBalance?.quantity == 600
        && store.convertedBalance(for: audEarmark.id)?.quantity == 400
        && store.convertedBalance(for: eurEarmark.id)?.quantity == 200
    }
  }
}
