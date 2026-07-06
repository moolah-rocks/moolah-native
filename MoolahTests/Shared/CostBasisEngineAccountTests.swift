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
  private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

  @Test
  func buyTaggedToAccount_visibleOnlyToThatAccount() {
    var engine = CostBasisEngine()
    engine.processBuy(
      instrument: eth, quantity: 1, costPerUnit: 2_000, date: day(0), account: accountA)
    #expect(engine.openLots(for: eth, account: accountA).count == 1)
    #expect(engine.openLots(for: eth, account: accountB).isEmpty)
    #expect(engine.openLots(for: eth).count == 1)  // aggregate across accounts
  }
}
