import Foundation
import Testing

@testable import Moolah

@Suite("AccountDetailLayout.showsPerformanceTiles")
struct AccountDetailPerformanceGateTests {
  let aud = Instrument.AUD
  let usd = Instrument.USD

  @Test("a non-zero non-host holding shows the tiles")
  func nonHostHoldingShowsTiles() {
    let rows = [
      ValuedPosition(
        instrument: aud, quantity: 1_000, unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 1_000, instrument: aud)),
      ValuedPosition(
        instrument: usd, quantity: 200, unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 304, instrument: aud)),
    ]
    #expect(AccountDetailLayout.showsPerformanceTiles(valuedRows: rows, hostCurrency: aud))
  }

  @Test("a host-only account hides the tiles (fiat-only)")
  func hostOnlyHidesTiles() {
    let rows = [
      ValuedPosition(
        instrument: aud, quantity: 1_000, unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 1_000, instrument: aud))
    ]
    #expect(!AccountDetailLayout.showsPerformanceTiles(valuedRows: rows, hostCurrency: aud))
  }

  @Test("an empty valued-rows set hides the tiles")
  func emptyHidesTiles() {
    #expect(!AccountDetailLayout.showsPerformanceTiles(valuedRows: [], hostCurrency: aud))
  }

  @Test("a zero-quantity non-host row does not show the tiles")
  func zeroQuantityNonHostHidesTiles() {
    let rows = [
      ValuedPosition(
        instrument: aud, quantity: 1_000, unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 1_000, instrument: aud)),
      ValuedPosition(
        instrument: usd, quantity: 0, unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 0, instrument: aud)),
    ]
    #expect(!AccountDetailLayout.showsPerformanceTiles(valuedRows: rows, hostCurrency: aud))
  }

  @Test("a non-host holding shows the tiles even without a converted value")
  func nonHostHoldingShowsTilesEvenUnpriced() {
    // Rule-11 graceful degradation: the strip still renders (current value
    // reads "Unavailable") when the row's value could not be converted.
    let rows = [
      ValuedPosition(
        instrument: usd, quantity: 200, unitPrice: nil, costBasis: nil, value: nil)
    ]
    #expect(AccountDetailLayout.showsPerformanceTiles(valuedRows: rows, hostCurrency: aud))
  }
}
