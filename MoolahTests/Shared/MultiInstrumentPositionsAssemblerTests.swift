import Foundation
import Testing

@testable import Moolah

@Suite("MultiInstrumentPositionsAssembler")
struct MultiInstrumentPositionsAssemblerTests {
  let aud = Instrument.AUD
  let btc = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8)
  let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
  let ltc = Instrument.crypto(
    chainId: 2, contractAddress: nil, symbol: "LTC", name: "Litecoin", decimals: 8)
  let accountA = UUID()
  let accountB = UUID()

  /// Day 0 = 2026-01-01. Uses `Calendar.utc` so the result is zone-invariant.
  private func date(daysAfterEpoch days: Int) -> Date {
    var components = DateComponents()
    components.year = 2026
    components.month = 1
    components.day = 1 + days
    guard let result = Calendar.utc.date(from: components) else {
      fatalError("Could not construct date \(days) days after 2026-01-01")
    }
    return result
  }

  private func buyTransaction(
    instrument: Instrument,
    qty: Decimal,
    fiat: Decimal,
    accountId: UUID,
    daysAfterEpoch days: Int
  ) -> Transaction {
    Transaction(
      date: date(daysAfterEpoch: days),
      legs: [
        TransactionLeg(accountId: accountId, instrument: instrument, quantity: qty, type: .trade),
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -fiat, type: .trade),
      ]
    )
  }

  // A crypto account holding a non-host token with a buy history produces an
  // input whose showsChart == true (non-empty series + a cost-bearing row).
  @Test
  func cryptoAccountInputShowsChart() async throws {
    let txns = [
      buyTransaction(
        instrument: btc, qty: 1, fiat: 50_000, accountId: accountA, daysAfterEpoch: 1)
    ]
    let service = FixedConversionService(rates: [btc.id: Decimal(60_000)])
    let assembler = MultiInstrumentPositionsAssembler(conversionService: service)

    let valuedRows = [
      ValuedPosition(
        instrument: btc, quantity: 1,
        unitPrice: InstrumentAmount(quantity: 60_000, instrument: aud),
        costBasis: nil,
        value: InstrumentAmount(quantity: 60_000, instrument: aud))
    ]

    let context = PositionsAssemblyContext(
      title: "BTC Account",
      hostCurrency: aud,
      accountIds: [accountA])
    let input = await assembler.assemble(
      context: context,
      valuedRows: valuedRows,
      transactions: txns,
      range: .all
    )

    #expect(input.historicalValue != nil)
    #expect(input.showsChart == true)
    #expect(input.showsPLPill == true)
    // The seeded buy was 1 BTC for 50_000 AUD, so the applied cost basis
    // quantity must equal exactly 50_000.
    #expect(input.positions.first?.costBasis?.quantity == 50_000)
  }

  // hasAnyTradeLeg is true when any account in the set has a non-host trade leg,
  // and false when there are none.
  @Test
  func hasAnyTradeLegAcrossAccounts() {
    let btcBuyA = Transaction(
      date: date(daysAfterEpoch: 1),
      legs: [
        TransactionLeg(accountId: accountA, instrument: btc, quantity: 1, type: .trade),
        TransactionLeg(accountId: accountA, instrument: aud, quantity: -50_000, type: .trade),
      ]
    )
    let fiatOnlyB = Transaction(
      date: date(daysAfterEpoch: 2),
      legs: [
        TransactionLeg(accountId: accountB, instrument: aud, quantity: -100, type: .expense)
      ]
    )

    // A set containing only accountB (fiat-only) — false.
    #expect(
      MultiInstrumentPositionsAssembler.hasAnyTradeLeg(
        in: [btcBuyA, fiatOnlyB], accountIds: [accountB], hostCurrency: aud) == false,
      "accountB only has a fiat leg, so hasAnyTradeLeg should be false"
    )

    // A set containing accountA (which has a non-host trade leg) — true.
    #expect(
      MultiInstrumentPositionsAssembler.hasAnyTradeLeg(
        in: [btcBuyA, fiatOnlyB], accountIds: [accountA], hostCurrency: aud) == true,
      "accountA has a BTC trade leg, so hasAnyTradeLeg should be true"
    )

    // Both accounts in the set — still true (accountA has the trade leg).
    #expect(
      MultiInstrumentPositionsAssembler.hasAnyTradeLeg(
        in: [btcBuyA, fiatOnlyB], accountIds: [accountA, accountB], hostCurrency: aud) == true,
      "the set includes accountA which has a BTC trade leg"
    )

    // Empty transaction list — false.
    #expect(
      MultiInstrumentPositionsAssembler.hasAnyTradeLeg(
        in: [], accountIds: [accountA, accountB], hostCurrency: aud) == false,
      "no transactions means no trade legs"
    )
  }

  // costBasisSnapshot omits an instrument whose classification fails while
  // keeping cleanly-classifiable instruments (Rule 11 — unavailable, not zero).
  //
  // Setup: LTC buy is fiat-paired (classifiable, no failing legs). ETH buy has
  // a BTC-denominated fee whose conversion fails — the classifier throws, so
  // ETH is added to the failed-classification set and dropped from the snapshot.
  // The test asserts BOTH properties: bad instrument absent AND good instrument
  // present with the correct exact host-currency cost.
  @Test
  func costBasisOmitsUnclassifiableInstrument() async {
    // BTC→AUD conversion fails; LTC→AUD and AUD→AUD always succeed.
    let service = FailingConversionService(
      rates: [ltc.id: Decimal(100)],
      failingInstrumentIds: [btc.id])
    let assembler = MultiInstrumentPositionsAssembler(conversionService: service)

    let txns = [
      // LTC fiat buy — cleanly classifiable (no BTC legs).
      // 5 LTC × 100 AUD/LTC = 500 AUD cost basis.
      Transaction(
        date: date(daysAfterEpoch: 1),
        legs: [
          TransactionLeg(accountId: accountA, instrument: ltc, quantity: 5, type: .trade),
          TransactionLeg(accountId: accountA, instrument: aud, quantity: -500, type: .trade),
        ]
      ),
      // ETH fiat buy with a BTC fee. The fee conversion (BTC→AUD) fails,
      // so `classify` throws and ETH is marked as unclassifiable.
      Transaction(
        date: date(daysAfterEpoch: 2),
        legs: [
          TransactionLeg(accountId: accountA, instrument: eth, quantity: 10, type: .trade),
          TransactionLeg(accountId: accountA, instrument: aud, quantity: -20_000, type: .trade),
          // BTC-denominated exchange fee — convert(BTC→AUD) will throw.
          TransactionLeg(accountId: accountA, instrument: btc, quantity: -1, type: .expense),
        ]
      ),
    ]

    let snapshot = await assembler.costBasisSnapshot(
      transactions: txns, accountIds: [accountA], hostCurrency: aud)

    // ETH classification failed (because the BTC fee conversion throws) →
    // omitted per Rule 11.
    #expect(snapshot[eth.id] == nil, "ETH should be omitted when its classification fails")
    // LTC classification succeeded → present with the exact cost.
    #expect(snapshot[ltc.id] != nil, "LTC should be present: its classification succeeded")
    #expect(snapshot[ltc.id] == 500, "LTC cost basis should equal 500 AUD (5 × 100)")
  }
}
