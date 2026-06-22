import Foundation
import Testing

@testable import Moolah

@Suite("AccountStore -- Conversion")
@MainActor
struct AccountStoreConversionTestsMore {
  @Test
  func displayBalanceForInvestmentAccountPrefersInvestmentValue() async throws {
    let accountId = UUID()
    // Default `recordedValue` mode — investment-value snapshot drives the balance.
    let account = Account(
      id: accountId, name: "Portfolio", type: .investment, instrument: .AUD)
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(accounts: [account], in: database)

    let usdTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .USD,
          quantity: dec("100.00"), type: .openingBalance)
      ]
    )
    TestBackend.seed(transactions: [usdTx], in: database)

    let conversion = FakeConversionService.fixedRates(["USD": dec("1.5")])
    let store = AccountStore(
      repository: backend.accounts, conversionService: conversion,
      targetInstrument: .AUD)
    // This wait is a load-bearing ORDERING BARRIER (not a read-gate): it ensures
    // the initial observeAll snapshot has landed before `updateInvestmentValue`,
    // so a late initial emission can't clobber the externally-set snapshot back
    // to zero. Do NOT replace it with a value poll.
    try await store.waitForNextEmission(
      matching: { !($0.positions(for: accountId).isEmpty) },
      description: "USD position observed"
    )

    // recordedValue + no snapshot → balance = 0 (positions are NOT a fallback).
    let sumBalance = try await store.displayBalance(for: accountId)
    #expect(sumBalance == .zero(instrument: .AUD))

    // Investment value set externally → recorded mode uses the snapshot verbatim.
    let externalValue = InstrumentAmount(
      quantity: dec("999.00"), instrument: .AUD)
    await store.updateInvestmentValue(accountId: accountId, value: externalValue)
    let override = try await store.displayBalance(for: accountId)
    #expect(override == externalValue)
  }

  @Test
  func displayBalanceForUnknownAccountReturnsZero() async throws {
    let (backend, _) = try TestBackend.create()
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument)
    try await store.waitForFirstEmission()
    let balance = try await store.displayBalance(for: UUID())
    #expect(balance == .zero(instrument: .defaultTestInstrument))
  }

  // MARK: - Partial conversion failures (sidebar bug)

  /// When one account's conversion fails, other accounts whose conversions
  /// succeed still appear in `convertedBalances`. Aggregate totals stay nil
  /// because we cannot accurately sum a set with a missing value.
  @Test
  func perAccountBalancePopulatesEvenWhenAnotherAccountFails() async throws {
    let aud = Instrument.AUD
    let usd = Instrument.USD
    let eur = Instrument.fiat(code: "EUR")
    let bankAud = Account(name: "AUD Bank", type: .bank, instrument: aud)
    let bankMixed = Account(name: "Mixed Bank", type: .bank, instrument: eur)

    let (backend, database) = try TestBackend.create()
    TestBackend.seed(accounts: [bankAud, bankMixed], in: database)
    let audTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: bankAud.id, instrument: aud,
          quantity: Decimal(1000), type: .openingBalance)
      ])
    let mixedEurTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: bankMixed.id, instrument: eur,
          quantity: Decimal(200), type: .openingBalance)
      ])
    let mixedUsdTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: bankMixed.id, instrument: usd,
          quantity: Decimal(50), type: .openingBalance)
      ])
    TestBackend.seed(transactions: [audTx, mixedEurTx, mixedUsdTx], in: database)

    // USD conversions fail; AUD and EUR conversions succeed (1:1 fallback).
    let conversion = FakeConversionService.failingInstruments(["USD"])
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: conversion,
      targetInstrument: aud,
      retryDelay: .seconds(60))

    // After the first emission settles, the partial-failure state is
    // observable:
    //   - AUD bank (only AUD positions) → succeeds with quantity 1000.
    //   - Mixed bank (EUR + USD) → needs USD→EUR which fails → nil.
    //   - Aggregate totals cannot be accurate with a missing unit → nil.
    await expectEventually("partial-failure state settles") {
      store.convertedBalances[bankAud.id]?.quantity == 1000
        && store.convertedBalances[bankMixed.id] == nil
        && store.convertedCurrentTotal == nil
        && store.convertedNetWorth == nil
    }
  }

  /// After the conversion service recovers, a retry populates the
  /// failed account balance and the aggregate totals.
  @Test
  func conversionFailuresAreRetriedAfterDelay() async throws {
    let aud = Instrument.AUD
    let eur = Instrument.fiat(code: "EUR")
    let bankAud = Account(name: "AUD Bank", type: .bank, instrument: aud)
    let bankEur = Account(name: "EUR Bank", type: .bank, instrument: eur)

    let (backend, database) = try TestBackend.create()
    TestBackend.seed(accounts: [bankAud, bankEur], in: database)
    let audTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: bankAud.id, instrument: aud,
          quantity: Decimal(1000), type: .openingBalance)
      ])
    let eurTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: bankEur.id, instrument: eur,
          quantity: Decimal(500), type: .openingBalance)
      ])
    TestBackend.seed(transactions: [audTx, eurTx], in: database)

    let conversion = FakeConversionService.failingInstruments(["EUR"])
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: conversion,
      targetInstrument: aud,
      retryDelay: .milliseconds(20))

    // Wait for the partial-failure state to land in the store.
    try await store.waitForNextEmission(
      matching: { $0.convertedCurrentTotal == nil && $0.accounts.count == 2 },
      description: "partial-failure observable"
    )

    // Recover the conversion service and wait for the background retry
    // loop to succeed. `waitForPendingConversions()` returns when the loop
    // terminates, which happens on the first successful attempt.
    conversion.setFailing([])
    await store.waitForPendingConversions()

    // 1000 AUD + 500 EUR (1:1 fallback) = 1500 AUD
    await expectEventually("retry repopulates balances and totals") {
      store.convertedCurrentTotal?.quantity == 1500
        && store.convertedNetWorth?.quantity == 1500
        && store.convertedBalances[bankAud.id]?.quantity == 1000
        && store.convertedBalances[bankEur.id]?.quantity == 500
    }
  }
  /// Regression for #96: `computeConvertedInvestmentTotal` must not route
  /// through `displayBalance` (which converts every position to the
  /// account's instrument) and then convert the bottom line again to the
  /// target. That extra hop doubles the round-trip through the conversion
  /// actor and doubles the retry blast radius when the outer hop fails.
  /// The implementation should mirror `computeConvertedCurrentTotal` and
  /// convert each position directly to `target` in one pass.
}
