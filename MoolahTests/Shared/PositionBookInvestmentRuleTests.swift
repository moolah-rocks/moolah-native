import Foundation
import Testing

@testable import Moolah

@Suite("PositionBook Investment Rule Tests")
struct PositionBookInvestmentRuleTests {

  // MARK: - Test Helpers

  private let bankAccount = UUID()
  private let investmentAccount = UUID()
  private let aud = Instrument.AUD
  private let date = Date(timeIntervalSince1970: 1_700_000_000)

  private func transaction(
    id: UUID = UUID(),
    date: Date? = nil,
    legs: [TransactionLeg]
  ) -> Transaction {
    Transaction(id: id, date: date ?? self.date, legs: legs)
  }

  // MARK: - dailyBalance — investment rules

  @Test("allLegs rule sums all investment-account positions")
  func allLegsRuleSumsAllInvestmentPositions() async throws {
    var book = PositionBook.empty
    // Transfer into investment account.
    book.apply(
      transaction(legs: [
        TransactionLeg(
          accountId: investmentAccount, instrument: aud, quantity: 1_000, type: .transfer)
      ]),
      investmentAccountIds: [investmentAccount])
    // Expense (e.g. capital loss / fee) on investment account.
    book.apply(
      transaction(legs: [
        TransactionLeg(
          accountId: investmentAccount, instrument: aud, quantity: -50, type: .expense)
      ]),
      investmentAccountIds: [investmentAccount])

    let conversion = FakeConversionService.fixedRates([:])

    let result = try await book.dailyBalance(
      on: date,
      context: PositionBook.BalanceContext(
        investmentAccountIds: [investmentAccount],
        profileInstrument: aud,
        rule: .allLegs,
        conversionService: conversion),
      isForecast: false
    )

    // .allLegs sees the full position: 1000 - 50 = 950.
    #expect(result.investments.quantity == 950)
    #expect(result.balance.quantity == 0)
  }

  @Test("investmentTransfersOnly rule sums only transfer-derived positions")
  func investmentTransfersOnlyRule() async throws {
    var book = PositionBook.empty
    // Transfer into investment account: contributes to both dicts.
    book.apply(
      transaction(legs: [
        TransactionLeg(
          accountId: investmentAccount, instrument: aud, quantity: 1_000, type: .transfer)
      ]),
      investmentAccountIds: [investmentAccount])
    // Income on investment account: contributes only to `accounts`.
    book.apply(
      transaction(legs: [
        TransactionLeg(
          accountId: investmentAccount, instrument: aud, quantity: 200, type: .income)
      ]),
      investmentAccountIds: [investmentAccount])

    let conversion = FakeConversionService.fixedRates([:])

    let result = try await book.dailyBalance(
      on: date,
      context: PositionBook.BalanceContext(
        investmentAccountIds: [investmentAccount],
        profileInstrument: aud,
        rule: .investmentTransfersOnly,
        conversionService: conversion),
      isForecast: false
    )

    // Only the transfer counts: 1000.
    #expect(result.investments.quantity == 1_000)
  }

  @Test("investment-account expense leg does not inflate transfers-only total")
  func expenseDoesNotInflateTransfersOnly() async throws {
    var book = PositionBook.empty
    // No transfers — only an expense on the investment account.
    book.apply(
      transaction(legs: [
        TransactionLeg(
          accountId: investmentAccount, instrument: aud, quantity: -100, type: .expense)
      ]),
      investmentAccountIds: [investmentAccount])

    let conversion = FakeConversionService.fixedRates([:])

    let result = try await book.dailyBalance(
      on: date,
      context: PositionBook.BalanceContext(
        investmentAccountIds: [investmentAccount],
        profileInstrument: aud,
        rule: .investmentTransfersOnly,
        conversionService: conversion),
      isForecast: false
    )

    // Expense leg never reaches accountsFromTransfers; investments total is 0.
    #expect(result.investments.quantity == 0)
    #expect(book.accountsFromTransfers.isEmpty)
  }

  // MARK: - apply(_:asStartingBalance:)

  @Test("apply with asStartingBalance: true records non-transfer investment legs in transfers")
  func startingBalanceRecordsNonTransferInvestmentLegs() async throws {
    var book = PositionBook.empty
    // Income on investment account, applied as a starting balance.
    book.apply(
      transaction(legs: [
        TransactionLeg(
          accountId: investmentAccount, instrument: aud, quantity: 700, type: .income)
      ]),
      investmentAccountIds: [investmentAccount],
      asStartingBalance: true)
    // Opening balance on investment account, applied as a starting balance.
    book.apply(
      transaction(legs: [
        TransactionLeg(
          accountId: investmentAccount, instrument: aud, quantity: 300,
          type: .openingBalance)
      ]),
      investmentAccountIds: [investmentAccount],
      asStartingBalance: true)

    // Both legs land in `accountsFromTransfers` because asStartingBalance == true.
    #expect(book.accountsFromTransfers[investmentAccount]?[aud] == 1_000)
    #expect(book.accounts[investmentAccount]?[aud] == 1_000)

    let conversion = FakeConversionService.fixedRates([:])
    let result = try await book.dailyBalance(
      on: date,
      context: PositionBook.BalanceContext(
        investmentAccountIds: [investmentAccount],
        profileInstrument: aud,
        rule: .investmentTransfersOnly,
        conversionService: conversion),
      isForecast: false
    )
    // .investmentTransfersOnly read sees the seeded baseline.
    #expect(result.investments.quantity == 1_000)
  }

  @Test("apply with asStartingBalance: false (default) leaves non-transfer investment legs out")
  func startingBalanceFalseExcludesNonTransferInvestmentLegs() {
    var book = PositionBook.empty
    // Default behaviour: only .transfer legs on investment accounts contribute
    // to accountsFromTransfers. An income leg on the investment account must
    // NOT appear in that dict.
    book.apply(
      transaction(legs: [
        TransactionLeg(
          accountId: investmentAccount, instrument: aud, quantity: 200, type: .income)
      ]),
      investmentAccountIds: [investmentAccount])

    #expect(book.accounts[investmentAccount]?[aud] == 200)
    #expect(book.accountsFromTransfers.isEmpty)
  }

  @Test(
    "apply with asStartingBalance: true is a no-op for accountsFromTransfers when no investment accounts"
  )
  func startingBalanceNoInvestmentAccountsIsNoOp() {
    var book = PositionBook.empty
    // Bank-only transaction with no investment accounts at all.
    book.apply(
      transaction(legs: [
        TransactionLeg(accountId: bankAccount, instrument: aud, quantity: 500, type: .income)
      ]),
      investmentAccountIds: [],
      asStartingBalance: true)

    #expect(book.accounts[bankAccount]?[aud] == 500)
    #expect(book.accountsFromTransfers.isEmpty)
  }

  @Test("investment-account transfer leg appears in both all-legs and transfers-only")
  func transferAppearsInBothRules() async throws {
    var book = PositionBook.empty
    book.apply(
      transaction(legs: [
        TransactionLeg(
          accountId: investmentAccount, instrument: aud, quantity: 500, type: .transfer)
      ]),
      investmentAccountIds: [investmentAccount])

    let conversion = FakeConversionService.fixedRates([:])

    let allLegs = try await book.dailyBalance(
      on: date,
      context: PositionBook.BalanceContext(
        investmentAccountIds: [investmentAccount],
        profileInstrument: aud,
        rule: .allLegs,
        conversionService: conversion),
      isForecast: false
    )
    let transfersOnly = try await book.dailyBalance(
      on: date,
      context: PositionBook.BalanceContext(
        investmentAccountIds: [investmentAccount],
        profileInstrument: aud,
        rule: .investmentTransfersOnly,
        conversionService: conversion),
      isForecast: false
    )

    #expect(allLegs.investments.quantity == 500)
    #expect(transfersOnly.investments.quantity == 500)
  }
}
