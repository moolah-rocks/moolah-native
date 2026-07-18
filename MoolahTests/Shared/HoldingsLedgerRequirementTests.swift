import Foundation
import Testing

@testable import Moolah

@Suite("Holdings ledger account-detail requirement")
struct HoldingsLedgerRequirementTests {
  private let aud = Instrument.AUD
  private let btc = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8)
  private let accountId = UUID()

  @Test("fiat-only account history does not require the holdings ledger")
  func fiatOnlyHistoryDoesNotRequireLedger() {
    let fiatTransaction = Transaction(
      date: Date(timeIntervalSince1970: 0),
      legs: [
        TransactionLeg(accountId: accountId, instrument: aud, quantity: 100, type: .income)
      ])
    let fiatRow = ValuedPosition(
      instrument: aud,
      quantity: 100,
      unitPrice: InstrumentAmount(quantity: 1, instrument: aud),
      costBasis: nil,
      value: InstrumentAmount(quantity: 100, instrument: aud))

    #expect(
      MultiInstrumentPositionsAssembler.requiresHoldingsLedger(
        alwaysShowsFullSurface: false,
        valuedRows: [fiatRow],
        transactions: [fiatTransaction],
        accountIds: [accountId],
        hostCurrency: aud) == false)
  }

  @Test("current non-host holdings require the holdings ledger")
  func nonHostHoldingRequiresLedger() {
    let bitcoinRow = ValuedPosition(
      instrument: btc,
      quantity: 1,
      unitPrice: InstrumentAmount(quantity: 60_000, instrument: aud),
      costBasis: nil,
      value: InstrumentAmount(quantity: 60_000, instrument: aud))

    #expect(
      MultiInstrumentPositionsAssembler.requiresHoldingsLedger(
        alwaysShowsFullSurface: false,
        valuedRows: [bitcoinRow],
        transactions: [],
        accountIds: [accountId],
        hostCurrency: aud))
  }

  @Test("sold historical trades still require the holdings ledger")
  func soldHistoricalTradeRequiresLedger() {
    let soldTrade = Transaction(
      date: Date(timeIntervalSince1970: 0),
      legs: [
        TransactionLeg(accountId: accountId, instrument: btc, quantity: 1, type: .trade),
        TransactionLeg(accountId: accountId, instrument: aud, quantity: -50_000, type: .trade),
      ])

    #expect(
      MultiInstrumentPositionsAssembler.requiresHoldingsLedger(
        alwaysShowsFullSurface: false,
        valuedRows: [],
        transactions: [soldTrade],
        accountIds: [accountId],
        hostCurrency: aud))
  }

  @Test("investment full surface requires the holdings ledger after all holdings are sold")
  func investmentFullSurfaceRequiresLedger() {
    #expect(
      MultiInstrumentPositionsAssembler.requiresHoldingsLedger(
        alwaysShowsFullSurface: true,
        valuedRows: [],
        transactions: [],
        accountIds: [accountId],
        hostCurrency: aud))
  }
}
