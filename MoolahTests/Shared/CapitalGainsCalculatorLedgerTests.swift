import Foundation
import Testing

@testable import Moolah

/// Ledger-sourced realisation cases for `CapitalGainsCalculator`: disposals
/// now draw on lots the profile-wide `HoldingsCostLedger` acquires from
/// non-fiat income / opening balances (valued at market on receipt), not only
/// fiat-paired `.trade` buys. Split into its own `@Suite` so the base
/// `CapitalGainsCalculatorTests` type stays within `type_body_length`.
@Suite("CapitalGainsCalculator — ledger acquisitions")
struct CapitalGainsCalculatorLedgerTests {
  private let aud = Instrument.fiat(code: "AUD")

  private func cryptoInstrument(_ symbol: String) -> Instrument {
    Instrument(
      id: "1:\(symbol.lowercased())", kind: .cryptoToken, name: symbol, decimals: 8,
      ticker: nil, exchange: nil, chainId: 1, contractAddress: nil)
  }

  private func date(_ daysFromBase: Int) -> Date {
    let calendar = Calendar(identifier: .gregorian)
    guard
      let base = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1)),
      let result = calendar.date(byAdding: .day, value: daysFromBase, to: base)
    else {
      fatalError("Could not construct date \(daysFromBase) days from 2024-01-01")
    }
    return result
  }

  @Test
  func receivedCrypto_thenSold_realisesGainFromMarketValueCostBase() async throws {
    let eth = cryptoInstrument("ETH")
    let account = UUID()
    let received = LegTransaction(
      date: date(0),
      legs: [TransactionLeg(accountId: account, instrument: eth, quantity: 1, type: .income)])
    let sold = LegTransaction(
      date: date(400),
      legs: [
        TransactionLeg(accountId: account, instrument: aud, quantity: 6_000, type: .trade),
        TransactionLeg(accountId: account, instrument: eth, quantity: -1, type: .trade),
      ])
    let result = try await CapitalGainsCalculator.computeWithConversion(
      transactions: [received, sold], profileCurrency: aud,
      conversionService: FakeConversionService.fixedRates([eth.id: 4_000]))  // receipt @ 4000
    // Cost base = market value on receipt (4000); proceeds = 6000 → gain 2000, long-term.
    #expect(result.events.count == 1)
    #expect(result.events[0].costBasis == 4_000)
    #expect(result.events[0].proceeds == 6_000)
    #expect(result.events[0].gain == 2_000)
    #expect(result.events[0].isLongTerm == true)
  }

  /// Rule 11: a genuine conversion failure for one instrument (ETH) drops its
  /// disposal from the realised set, so the CGT total may be understated.
  /// `compute(ledger:)` must FLAG this (`hasUnavailableData`) — a tax figure
  /// must never render complete-but-wrong — while a sibling instrument (BHP,
  /// all-AUD, resolves) still realises normally.
  @Test
  func unavailableConversion_flagsCgtResult_siblingStillRealises() async throws {
    let eth = cryptoInstrument("ETH")
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let account = UUID()
    let txns: [LegTransaction] = [
      // ETH received — market conversion FAILS → its later disposal finds no
      // lot and cannot realise; ETH is marked unavailable.
      LegTransaction(
        date: date(0),
        legs: [TransactionLeg(accountId: account, instrument: eth, quantity: 1, type: .income)]),
      LegTransaction(
        date: date(400),
        legs: [
          TransactionLeg(accountId: account, instrument: aud, quantity: 6_000, type: .trade),
          TransactionLeg(accountId: account, instrument: eth, quantity: -1, type: .trade),
        ]),
      // BHP fiat-paired buy + sale — all AUD, resolves fine.
      LegTransaction(
        date: date(0),
        legs: [
          TransactionLeg(accountId: account, instrument: aud, quantity: -4_000, type: .trade),
          TransactionLeg(accountId: account, instrument: bhp, quantity: 100, type: .trade),
        ]),
      LegTransaction(
        date: date(400),
        legs: [
          TransactionLeg(accountId: account, instrument: bhp, quantity: -100, type: .trade),
          TransactionLeg(accountId: account, instrument: aud, quantity: 5_000, type: .trade),
        ]),
    ]
    let result = try await CapitalGainsCalculator.computeWithConversion(
      transactions: txns, profileCurrency: aud,
      conversionService: FakeConversionService.failingInstruments([eth.id]))
    #expect(result.hasUnavailableData)  // ETH conversion failed → possibly undercounted
    #expect(result.events.contains { $0.instrument == bhp })  // sibling still realised
    #expect(!result.events.contains { $0.instrument == eth })  // ETH disposal dropped
  }

  @Test
  func unavailableInputScopesRealisedGainRiskToDisposalKeys() {
    let eth = cryptoInstrument("ETH")
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let account = UUID()
    let group = HoldingsCostLedger.TransactionGroup(
      id: UUID(),
      date: date(400),
      legs: [
        TransactionLeg(accountId: account, instrument: aud, quantity: 6_000, type: .trade),
        TransactionLeg(accountId: account, instrument: bhp, quantity: -100, type: .trade),
        TransactionLeg(accountId: account, instrument: eth, quantity: 1, type: .trade),
      ],
      taxOwnerIdsByAccount: [:],
      taxOwnerIdsByLegId: [:])

    var unavailable: Set<HoldingsCostLedger.TouchKey> = []
    var inputs: Set<HoldingsCostLedgerUnavailableInput> = []

    HoldingsCostLedger.recordUnavailableInput(
      for: group,
      error: TestConversionError(),
      unavailable: &unavailable,
      inputs: &inputs)

    let bhpKey = HoldingsCostLedger.TouchKey(account: account, instrument: bhp, taxOwnerId: nil)
    let ethKey = HoldingsCostLedger.TouchKey(account: account, instrument: eth, taxOwnerId: nil)
    #expect(unavailable == [bhpKey, ethKey])
    #expect(
      inputs.contains(
        HoldingsCostLedgerUnavailableInput(
          date: group.date, keys: [bhpKey], mayAffectRealisedGains: true)))
    #expect(
      inputs.contains(
        HoldingsCostLedgerUnavailableInput(
          date: group.date, keys: [ethKey], mayAffectRealisedGains: false)))
    #expect(
      !inputs.contains {
        $0.mayAffectRealisedGains && $0.keys.contains(ethKey)
      })
  }

  private struct TestConversionError: Error {}
}
