import Foundation
import Testing

@testable import Moolah

@Suite("Transaction.displayAmounts")
struct TransactionDisplayAmountTests {
  let aud = Instrument.AUD
  let usd = Instrument.fiat(code: "USD")
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let accountA = UUID()
  let accountB = UUID()
  let earmarkId = UUID()
  let date = Date(timeIntervalSince1970: 1_700_000_000)

  private func leg(
    _ accountId: UUID?,
    _ instr: Instrument,
    _ qty: Decimal,
    _ type: TransactionType,
    earmark: UUID? = nil
  ) -> TransactionLeg {
    TransactionLeg(
      accountId: accountId, instrument: instr, quantity: qty,
      type: type, earmarkId: earmark)
  }

  @Test("simple expense scoped to its account: one entry")
  func simpleExpense() async {
    let transaction = Transaction(date: date, legs: [leg(accountA, aud, -50, .expense)])
    let result = await TransactionPage.withRunningBalances(
      transactions: [transaction],
      priorBalance: InstrumentAmount(quantity: 100, instrument: aud),
      accountId: accountA, targetInstrument: aud,
      conversionService: FakeConversionService.fixedRates([:]))
    #expect(
      result.rows[0].displayAmounts == [InstrumentAmount(quantity: -50, instrument: aud)])
  }

  @Test("trade with cross-currency fee: three entries (legs not summed)")
  func tradeWithCrossCurrencyFee() async {
    let transaction = Transaction(
      date: date,
      legs: [
        leg(accountA, aud, -300, .trade),
        leg(accountA, bhp, 2, .trade),
        leg(accountA, usd, -10, .expense),
      ])
    let result = await TransactionPage.withRunningBalances(
      transactions: [transaction],
      priorBalance: InstrumentAmount(quantity: 5_000, instrument: aud),
      accountId: accountA, targetInstrument: aud,
      conversionService: FakeConversionService.fixedRates([
        bhp.id: Decimal(150), usd.id: Decimal(1.5),
      ]))
    let amounts = Set(result.rows[0].displayAmounts)
    #expect(
      amounts
        == Set([
          InstrumentAmount(quantity: -300, instrument: aud),
          InstrumentAmount(quantity: 2, instrument: bhp),
          InstrumentAmount(quantity: -10, instrument: usd),
        ]))
  }

  @Test("trade with same-currency fee: AUD legs sum")
  func tradeWithSameCurrencyFee() async {
    let transaction = Transaction(
      date: date,
      legs: [
        leg(accountA, aud, -300, .trade),
        leg(accountA, bhp, 2, .trade),
        leg(accountA, aud, -10, .expense),
      ])
    let result = await TransactionPage.withRunningBalances(
      transactions: [transaction],
      priorBalance: InstrumentAmount(quantity: 5_000, instrument: aud),
      accountId: accountA, targetInstrument: aud,
      conversionService: FakeConversionService.fixedRates([bhp.id: Decimal(150)]))
    let amounts = Set(result.rows[0].displayAmounts)
    #expect(
      amounts
        == Set([
          InstrumentAmount(quantity: -310, instrument: aud),
          InstrumentAmount(quantity: 2, instrument: bhp),
        ]))
  }

  @Test("cross-currency transfer scoped to source: only AUD entry")
  func crossCurrencyTransferSourceScope() async {
    let transaction = Transaction(
      date: date,
      legs: [
        leg(accountA, aud, -1_000, .transfer),
        leg(accountB, usd, 660, .transfer),
      ])
    let result = await TransactionPage.withRunningBalances(
      transactions: [transaction],
      priorBalance: InstrumentAmount(quantity: 5_000, instrument: aud),
      accountId: accountA, targetInstrument: aud,
      conversionService: FakeConversionService.fixedRates([usd.id: Decimal(1.5)]))
    #expect(
      result.rows[0].displayAmounts == [InstrumentAmount(quantity: -1_000, instrument: aud)])
  }

  @Test("same-currency transfer unfiltered: zero-sum fallback shows negative leg")
  func sameCurrencyTransferUnfiltered() async {
    let transaction = Transaction(
      date: date,
      legs: [
        leg(accountA, aud, -200, .transfer),
        leg(accountB, aud, 200, .transfer),
      ])
    let result = await TransactionPage.withRunningBalances(
      transactions: [transaction], priorBalance: nil,
      accountId: nil, targetInstrument: aud,
      conversionService: FakeConversionService.fixedRates([:]))
    #expect(
      result.rows[0].displayAmounts == [InstrumentAmount(quantity: -200, instrument: aud)])
  }

  @Test("earmark scope: only legs touching the earmark are summed")
  func earmarkScope() async {
    let transaction = Transaction(
      date: date,
      legs: [
        leg(accountA, aud, 100, .income, earmark: earmarkId),
        leg(accountA, aud, -10, .expense),  // not earmarked
      ])
    let result = await TransactionPage.withRunningBalances(
      transactions: [transaction], priorBalance: nil, accountId: nil, earmarkId: earmarkId,
      targetInstrument: aud, conversionService: FakeConversionService.fixedRates([:]))
    #expect(
      result.rows[0].displayAmounts == [InstrumentAmount(quantity: 100, instrument: aud)])
  }
}
