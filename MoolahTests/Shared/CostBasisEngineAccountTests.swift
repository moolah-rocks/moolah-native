import Foundation
import Testing

@testable import Moolah

@Suite("CostBasisEngine account tagging")
struct CostBasisEngineAccountTests {
  private let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
  private let accountA = UUID()
  private let accountB = UUID()

  private func day(_ n: Int) -> Date {
    Date(timeIntervalSince1970: 1_700_000_000 + Double(n) * 86_400)
  }

  @Test
  func buyTaggedToAccount_visibleOnlyToThatAccount() {
    var engine = CostBasisEngine()
    engine.processBuy(
      instrument: eth, quantity: 1, costPerUnit: 2_000, date: day(0), account: accountA)
    #expect(engine.openLots(for: eth, account: accountA).count == 1)
    #expect(engine.openLots(for: eth, account: accountB).isEmpty)
    #expect(engine.allOpenLots(for: eth).count == 1)  // aggregate across accounts
  }

  @Test
  func moveLots_sameAccount_isNoOp() {
    var engine = CostBasisEngine()
    engine.processBuy(
      instrument: eth, quantity: 2, costPerUnit: 2_000, date: day(0), account: accountA)
    engine.moveLots(instrument: eth, quantity: 2, from: accountA, to: accountA)

    let lots = engine.openLots(for: eth, account: accountA)
    #expect(lots.count == 1)
    #expect(lots[0].remainingQuantity == 2)
  }

  @Test
  func moveLots_sameNilAccount_isNoOp() {
    var engine = CostBasisEngine()
    engine.processBuy(instrument: eth, quantity: 2, costPerUnit: 2_000, date: day(0))
    engine.moveLots(instrument: eth, quantity: 2, from: nil, to: nil)

    let lots = engine.openLots(for: eth, account: nil)
    #expect(lots.count == 1)
    #expect(lots[0].remainingQuantity == 2)
  }

  @Test
  func moveLots_preservesCostAndDate_shiftsRemainingInvested() {
    var engine = CostBasisEngine()
    engine.processBuy(
      instrument: eth, quantity: 2, costPerUnit: 2_000, date: day(0), account: accountA)
    engine.moveLots(instrument: eth, quantity: 2, from: accountA, to: accountB)

    #expect(engine.openLots(for: eth, account: accountA).isEmpty)
    let moved = engine.openLots(for: eth, account: accountB)
    #expect(moved.count == 1)
    #expect(moved[0].costPerUnit == 2_000)  // cost preserved
    #expect(moved[0].acquiredDate == day(0))  // 12-month clock NOT reset
    #expect(moved[0].remainingQuantity == 2)
    // Source remaining invested drops to 0; destination rises by the same 4000.
    #expect(
      engine.openLots(for: eth, account: accountA).reduce(Decimal(0)) { $0 + $1.remainingCost }
        == 0)
    #expect(moved.reduce(Decimal(0)) { $0 + $1.remainingCost } == 4_000)
  }

  @Test
  func moveLots_partial_movesFIFOAndLeavesRemainder() {
    var engine = CostBasisEngine()
    engine.processBuy(
      instrument: eth, quantity: 1, costPerUnit: 2_000, date: day(0), account: accountA)
    engine.processBuy(
      instrument: eth, quantity: 1, costPerUnit: 3_000, date: day(10), account: accountA)
    engine.moveLots(instrument: eth, quantity: dec("1.5"), from: accountA, to: accountB)

    // FIFO: whole 2000-lot + 0.5 of the 3000-lot move; 0.5 of the 3000-lot stays.
    #expect(engine.openLots(for: eth, account: accountB).count == 2)
    let remainA = engine.openLots(for: eth, account: accountA)
    #expect(remainA.count == 1)
    #expect(remainA[0].remainingQuantity == dec("0.5"))
    #expect(remainA[0].costPerUnit == 3_000)
  }
}
