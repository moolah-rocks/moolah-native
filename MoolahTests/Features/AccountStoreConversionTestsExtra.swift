import Foundation
import Testing

@testable import Moolah

@Suite("AccountStore -- Conversion")
@MainActor
struct AccountStoreConversionTestsExtra {
  @Test
  func mixedKindAccountShowsFiatAndStockPositions() async throws {
    let accountId = UUID()
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let account = Account(
      id: accountId, name: "Sharesight", type: .investment,
      instrument: .defaultTestInstrument)
    let (backend, database) = try TestBackend.create()
    try await TestBackend.register(bhp, in: backend)
    TestBackend.seed(accounts: [account], in: database)

    let audTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .AUD,
          quantity: dec("5000.00"), type: .openingBalance)
      ]
    )
    let stockTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: Decimal(100),
          type: .transfer)
      ]
    )
    TestBackend.seed(transactions: [audTx, stockTx], in: database)

    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument
    )
    await expectEventually("both fiat and stock positions settle") {
      let positions = store.positions(for: accountId)
      return positions.count == 2
        && positions.contains { $0.instrument == .AUD }
        && positions.contains { $0.instrument == bhp }
    }
  }

  @Test
  func mixedKindAccountShowsFiatStockAndCryptoPositions() async throws {
    let accountId = UUID()
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
    )
    let account = Account(
      id: accountId, name: "Portfolio", type: .investment,
      instrument: .defaultTestInstrument)
    let (backend, database) = try TestBackend.create()
    try await TestBackend.register(bhp, in: backend)
    try await TestBackend.register(eth, in: backend)
    TestBackend.seed(accounts: [account], in: database)

    let txns = [
      Transaction(
        date: Date(),
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: .AUD,
            quantity: dec("1000.00"), type: .openingBalance)
        ]),
      Transaction(
        date: Date(),
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: bhp, quantity: Decimal(100),
            type: .transfer)
        ]),
      Transaction(
        date: Date(),
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: eth,
            quantity: dec("0.5"), type: .transfer)
        ]),
    ]
    TestBackend.seed(transactions: txns, in: database)

    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument
    )
    await expectEventually("fiat, stock and crypto positions all settle") {
      let positions = store.positions(for: accountId)
      return positions.count == 3
        && Set(positions.map(\.instrument.kind)) == [.fiatCurrency, .stock, .cryptoToken]
    }
  }

  // MARK: - displayBalance

  @Test
  func displayBalanceSumsAllPositionsInAccountInstrument() async throws {
    let accountId = UUID()
    let account = Account(
      id: accountId, name: "Revolut", type: .bank, instrument: .AUD)
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(accounts: [account], in: database)

    let audTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .AUD,
          quantity: dec("1000.00"), type: .openingBalance)
      ]
    )
    let usdTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .USD,
          quantity: dec("200.00"), type: .openingBalance)
      ]
    )
    TestBackend.seed(transactions: [audTx, usdTx], in: database)

    // 1 USD = 1.5 AUD
    let conversion = FakeConversionService.fixedRates(["USD": dec("1.5")])
    let store = AccountStore(
      repository: backend.accounts, conversionService: conversion,
      targetInstrument: .AUD)
    // 1000 AUD + 200 USD * 1.5 = 1300 AUD
    await expectEventually("display balance sums positions in AUD") {
      let balance = try? await store.displayBalance(for: accountId)
      return balance?.instrument == .AUD && balance?.quantity == dec("1300.00")
    }
  }

  @Test
  func displayBalanceForSingleCurrencyAccountReturnsPrimaryPosition() async throws {
    let accountId = UUID()
    let account = Account(
      id: accountId, name: "Bank", type: .bank, instrument: .defaultTestInstrument)
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(accounts: [account], in: database)

    let transaction = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .defaultTestInstrument,
          quantity: dec("750.00"), type: .openingBalance)
      ]
    )
    TestBackend.seed(transactions: [transaction], in: database)

    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument)
    await expectEventually("single-currency display balance settles") {
      let balance = try? await store.displayBalance(for: accountId)
      return balance?.quantity == dec("750.00") && balance?.instrument == .defaultTestInstrument
    }
  }
}
