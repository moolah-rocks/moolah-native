import Foundation
import Testing

@testable import Moolah

@Suite("PositionBook Tests")
struct PositionBookTests {

  // MARK: - Test Helpers

  private let bankAccount = UUID()
  private let bankAccount2 = UUID()
  private let earmarkA = UUID()
  private let earmarkB = UUID()
  private let aud = Instrument.AUD
  private let usd = Instrument.USD
  private let date = Date(timeIntervalSince1970: 1_700_000_000)

  private func transaction(
    id: UUID = UUID(),
    date: Date? = nil,
    legs: [TransactionLeg]
  ) -> Transaction {
    Transaction(id: id, date: date ?? self.date, legs: legs)
  }

  // MARK: - Empty / Apply

  @Test("empty book has no positions")
  func emptyBookHasNoPositions() {
    let book = PositionBook.empty
    #expect(book.accounts.isEmpty)
    #expect(book.earmarks.isEmpty)
    #expect(book.earmarksSaved.isEmpty)
    #expect(book.earmarksSpent.isEmpty)
    #expect(book.accountsFromTransfers.isEmpty)
    #expect(book == PositionBook())
  }

  @Test("applying a single-leg transaction records the position")
  func applySingleLegRecordsPosition() {
    var book = PositionBook.empty
    let leg = TransactionLeg(
      accountId: bankAccount, instrument: aud, quantity: -50, type: .expense,
      earmarkId: earmarkA)
    book.apply(transaction(legs: [leg]))

    #expect(book.accounts[bankAccount]?[aud] == -50)
    #expect(book.earmarks[earmarkA]?[aud] == -50)
    #expect(book.earmarksSpent[earmarkA]?[aud] == 50)
    #expect(book.earmarksSaved.isEmpty)
    #expect(book.accountsFromTransfers.isEmpty)
  }

  @Test("applying a transaction records all its legs")
  func applyTransactionRecordsAllLegs() {
    var book = PositionBook.empty
    let txn = transaction(legs: [
      TransactionLeg(accountId: bankAccount, instrument: aud, quantity: -200, type: .transfer),
      TransactionLeg(accountId: bankAccount2, instrument: aud, quantity: 200, type: .transfer),
    ])
    book.apply(txn)

    #expect(book.accounts[bankAccount]?[aud] == -200)
    #expect(book.accounts[bankAccount2]?[aud] == 200)
  }

  @Test("sign = -1 reverses an application")
  func signMinusOneReverses() {
    var book = PositionBook.empty
    let txn = transaction(legs: [
      TransactionLeg(
        accountId: bankAccount, instrument: aud, quantity: 100, type: .income,
        earmarkId: earmarkA)
    ])
    book.apply(txn, sign: 1)
    book.apply(txn, sign: -1)
    book.cleanZeros()

    #expect(book == PositionBook.empty)
  }

  @Test("applying old-sign-negative then new-sign-positive matches BalanceDeltaCalculator")
  func matchesBalanceDeltaCalculator() {
    let txId = UUID()
    let oldTxn = transaction(
      id: txId,
      legs: [
        TransactionLeg(
          accountId: bankAccount, instrument: aud, quantity: -50, type: .expense,
          earmarkId: earmarkA)
      ])
    let newTxn = transaction(
      id: txId,
      legs: [
        TransactionLeg(
          accountId: bankAccount, instrument: aud, quantity: -80, type: .expense,
          earmarkId: earmarkB),
        TransactionLeg(
          accountId: bankAccount2, instrument: usd, quantity: 30, type: .income,
          earmarkId: earmarkA),
      ])

    var book = PositionBook.empty
    book.apply(oldTxn, sign: -1)
    book.apply(newTxn, sign: 1)
    book.cleanZeros()

    let delta = BalanceDeltaCalculator.deltas(old: oldTxn, new: newTxn)

    #expect(book.accounts == delta.accountDeltas)
    #expect(book.earmarks == delta.earmarkDeltas)
    #expect(book.earmarksSaved == delta.earmarkSavedDeltas)
    #expect(book.earmarksSpent == delta.earmarkSpentDeltas)
  }

  // MARK: - cleanZeros

  @Test("cleanZeros removes zero-valued instruments and empty entities")
  func cleanZerosRemovesEmpty() {
    var book = PositionBook.empty
    let txn = transaction(legs: [
      TransactionLeg(accountId: bankAccount, instrument: aud, quantity: 100, type: .income)
    ])
    book.apply(txn, sign: 1)
    book.apply(txn, sign: -1)

    // Pre-clean: zero entry exists.
    #expect(book.accounts[bankAccount]?[aud] == 0)

    book.cleanZeros()

    #expect(book.accounts.isEmpty)
  }

  // MARK: - dailyBalance — single instrument

  @Test("single-instrument dailyBalance returns raw quantities without conversion")
  func singleInstrumentDailyBalanceSkipsConversion() async throws {
    var book = PositionBook.empty
    book.apply(
      transaction(legs: [
        TransactionLeg(accountId: bankAccount, instrument: aud, quantity: 1_000, type: .income)
      ]))
    book.apply(
      transaction(legs: [
        TransactionLeg(accountId: bankAccount, instrument: aud, quantity: -150, type: .expense)
      ]))

    // Tuned with a non-1 USD rate to prove the fast path is taken: if the
    // conversion service were called, totals would change.
    let conversion = FakeConversionService.fixedRates(["USD": 999])

    let result = try await book.dailyBalance(
      on: date,
      context: PositionBook.BalanceContext(
        investmentAccountIds: [],
        profileInstrument: aud,
        rule: .allLegs,
        conversionService: conversion),
      isForecast: false
    )

    #expect(result.balance.quantity == 850)
    #expect(result.balance.instrument == aud)
    #expect(result.investments.quantity == 0)
    #expect(result.earmarked.quantity == 0)
    #expect(result.availableFunds.quantity == 850)
    #expect(result.netWorth.quantity == 850)
    #expect(result.investmentValue == nil)
    #expect(result.bestFit == nil)
    #expect(result.isForecast == false)
  }

  // MARK: - dailyBalance — multi instrument

  @Test("multi-instrument dailyBalance converts at the given date's rates")
  func multiInstrumentDailyBalanceConverts() async throws {
    var book = PositionBook.empty
    // 100 AUD in bank account.
    book.apply(
      transaction(legs: [
        TransactionLeg(accountId: bankAccount, instrument: aud, quantity: 100, type: .income)
      ]))
    // 50 USD in another bank account — should be converted at 1.5 AUD/USD = 75 AUD.
    book.apply(
      transaction(legs: [
        TransactionLeg(accountId: bankAccount2, instrument: usd, quantity: 50, type: .income)
      ]))

    // Date-aware: anchoring the rate at `date` ensures a regression where
    // `dailyBalance(on:)` accidentally passed `Date()` instead of the
    // requested snapshot date would surface as a missing rate (1:1
    // fallback) and fail the assertion. Per
    // `guides/INSTRUMENT_CONVERSION_GUIDE.md` §6.
    let conversion = FakeConversionService.dateRates([date: ["USD": 1.5]])

    let result = try await book.dailyBalance(
      on: date,
      context: PositionBook.BalanceContext(
        investmentAccountIds: [],
        profileInstrument: aud,
        rule: .allLegs,
        conversionService: conversion),
      isForecast: false
    )

    // 100 AUD + (50 USD × 1.5) = 175 AUD
    #expect(result.balance.quantity == 175)
    #expect(result.balance.instrument == aud)
  }

  // MARK: - dailyBalance — earmarks

  @Test("earmarks are per-earmark clamped to zero before summing")
  func earmarksClampedPerEarmark() async throws {
    var book = PositionBook.empty
    // earmarkA: -200 (negative — should be clamped to 0).
    book.apply(
      transaction(legs: [
        TransactionLeg(
          accountId: bankAccount, instrument: aud, quantity: -200, type: .expense,
          earmarkId: earmarkA)
      ]))
    // earmarkB: +500 (positive — counted in full).
    book.apply(
      transaction(legs: [
        TransactionLeg(
          accountId: bankAccount, instrument: aud, quantity: 500, type: .income,
          earmarkId: earmarkB)
      ]))

    let conversion = FakeConversionService.fixedRates([:])

    let result = try await book.dailyBalance(
      on: date,
      context: PositionBook.BalanceContext(
        investmentAccountIds: [],
        profileInstrument: aud,
        rule: .allLegs,
        conversionService: conversion),
      isForecast: false
    )

    // earmarkA clamped to 0, earmarkB contributes 500, total = 500.
    // (Naive sum without clamping would be -200 + 500 = 300.)
    #expect(result.earmarked.quantity == 500)
  }
}
