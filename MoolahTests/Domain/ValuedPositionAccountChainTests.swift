import Foundation
import Testing

@testable import Moolah

@Suite("ValuedPosition.accountChainId")
struct ValuedPositionAccountChainTests {
  @Test("Defaults to nil when omitted (existing call sites unaffected)")
  func defaultsNil() {
    let pos = ValuedPosition(
      instrument: .crypto(
        chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18),
      quantity: 1, unitPrice: nil, costBasis: nil, value: nil)
    #expect(pos.accountChainId == nil)
  }

  @Test("Round-trips the owning account chain when supplied")
  func carriesChain() {
    let pos = ValuedPosition(
      instrument: .crypto(
        chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18),
      quantity: 1, unitPrice: nil, costBasis: nil, value: nil, accountChainId: 10)
    #expect(pos.accountChainId == 10)
  }
}
