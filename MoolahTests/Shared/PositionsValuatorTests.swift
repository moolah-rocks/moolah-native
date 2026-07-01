import Foundation
import Testing

@testable import Moolah

@Suite("PositionsValuator")
struct PositionsValuatorTests {
  let aud = Instrument.AUD
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let cba = Instrument.stock(ticker: "CBA.AX", exchange: "ASX", name: "CBA")

  @Test("converts each position to host currency on the given date")
  func convertsAll() async throws {
    let positions = [
      Position(instrument: bhp, quantity: 250),
      Position(instrument: cba, quantity: 80),
    ]
    let service = FakeConversionService.fixedRates([
      bhp.id: Decimal(45.30),
      cba.id: Decimal(120),
    ])
    let valuator = PositionsValuator(conversionService: service)
    let rows = await valuator.valuate(
      positions: positions,
      hostCurrency: aud,
      costBasis: [:],
      on: Date()
    )

    let bhpRow = try #require(rows.first(where: { $0.instrument == bhp }))
    let cbaRow = try #require(rows.first(where: { $0.instrument == cba }))
    #expect(bhpRow.value == InstrumentAmount(quantity: 250 * Decimal(45.30), instrument: aud))
    #expect(bhpRow.unitPrice == InstrumentAmount(quantity: Decimal(45.30), instrument: aud))
    #expect(cbaRow.value == InstrumentAmount(quantity: 80 * Decimal(120), instrument: aud))
  }

  @Test("single-instrument fast path skips the conversion service")
  func fastPath() async throws {
    let positions = [Position(instrument: aud, quantity: 1_000)]
    // service throws for any conversion — must not be called for AUD->AUD.
    let service = FakeConversionService.failingInstruments([aud.id])
    let valuator = PositionsValuator(conversionService: service)
    let rows = await valuator.valuate(
      positions: positions, hostCurrency: aud,
      costBasis: [:], on: Date()
    )
    #expect(rows.count == 1)
    #expect(rows[0].value == InstrumentAmount(quantity: 1_000, instrument: aud))
    // unitPrice is nil for the fast-path fiat row; meaningless to display
    // 1 AUD = $1.
    #expect(rows[0].unitPrice == nil)
  }

  @Test("per-row conversion failure leaves value nil; siblings still render")
  func perRowFailure() async throws {
    let positions = [
      Position(instrument: bhp, quantity: 100),
      Position(instrument: cba, quantity: 50),
    ]
    let service = FakeConversionService.failingInstruments(
      [cba.id],
      rates: [bhp.id: Decimal(40)]
    )
    let valuator = PositionsValuator(conversionService: service)
    let rows = await valuator.valuate(
      positions: positions, hostCurrency: aud,
      costBasis: [:], on: Date()
    )
    let bhpRow = try #require(rows.first(where: { $0.instrument == bhp }))
    let cbaRow = try #require(rows.first(where: { $0.instrument == cba }))
    #expect(bhpRow.value != nil)
    #expect(cbaRow.value == nil)
    #expect(cbaRow.quantity == 50)  // qty still rendered
  }

  @Test("cost basis snapshot is propagated into the row")
  func costBasisPropagated() async throws {
    let positions = [Position(instrument: bhp, quantity: 100)]
    let service = FakeConversionService.fixedRates([bhp.id: Decimal(50)])
    let valuator = PositionsValuator(conversionService: service)
    let rows = await valuator.valuate(
      positions: positions, hostCurrency: aud,
      costBasis: [bhp.id: Decimal(4_000)], on: Date()
    )
    #expect(rows[0].costBasis == InstrumentAmount(quantity: 4_000, instrument: aud))
  }

  @Test("empty positions input returns an empty array")
  func emptyInput() async {
    let service = FakeConversionService.fixedRates([:])
    let valuator = PositionsValuator(conversionService: service)
    let rows = await valuator.valuate(
      positions: [], hostCurrency: aud, costBasis: [:], on: Date())
    #expect(rows.isEmpty)
  }

  @Test("zero-quantity position has nil unitPrice (no division by zero)")
  func zeroQuantityUnitPrice() async {
    let positions = [Position(instrument: bhp, quantity: 0)]
    let service = FakeConversionService.fixedRates([bhp.id: Decimal(40)])
    let valuator = PositionsValuator(conversionService: service)
    let rows = await valuator.valuate(
      positions: positions, hostCurrency: aud, costBasis: [:], on: Date())
    #expect(rows.count == 1)
    #expect(rows[0].unitPrice == nil)
  }

  @Test("stamps the supplied owning account chain id onto every built row")
  func stampsAccountChainId() async throws {
    let eth = Instrument.crypto(
      chainId: 10, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    let positions = [
      Position(instrument: aud, quantity: 1_000),  // host-currency fast path
      Position(instrument: eth, quantity: 2),  // cross-instrument path
    ]
    let service = FakeConversionService.fixedRates([eth.id: Decimal(4_000)])
    let valuator = PositionsValuator(conversionService: service)
    let rows = await valuator.valuate(
      positions: positions, hostCurrency: aud, costBasis: [:], on: Date(),
      accountChainId: 10)
    #expect(rows.count == 2)
    #expect(rows.allSatisfy { $0.accountChainId == 10 })
  }

  @Test("omitting the owning chain leaves accountChainId nil")
  func defaultsAccountChainIdNil() async throws {
    let positions = [Position(instrument: bhp, quantity: 100)]
    let service = FakeConversionService.fixedRates([bhp.id: Decimal(50)])
    let valuator = PositionsValuator(conversionService: service)
    let rows = await valuator.valuate(
      positions: positions, hostCurrency: aud, costBasis: [:], on: Date())
    #expect(rows[0].accountChainId == nil)
  }

  @Test("single crypto wallet chain folds into a holding's contributingChainIds")
  func chainFoldsThroughValuator() async throws {
    let eth = Instrument.crypto(
      chainId: 10, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    let service = FakeConversionService.fixedRates([eth.id: Decimal(4_000)])
    let valuator = PositionsValuator(conversionService: service)
    let rows = await valuator.valuate(
      positions: [Position(instrument: eth, quantity: 2)],
      hostCurrency: aud, costBasis: [:], on: Date(), accountChainId: 10)
    let holdings = AssetHolding.fold(rows, assetKeys: [eth.id: "ethereum"], hostCurrency: aud)
    let holding = try #require(holdings.first)
    #expect(holding.contributingChainIds.contains(10))
  }

  @Test("negative quantity (short position) preserves sign in value, positive unit price")
  func shortPositionSignPreservation() async throws {
    // Short -10 shares of BHP @ $40 each → value = -$400 (you owe $400 worth),
    // unit price = $40 (one share is still worth $40 regardless of position sign).
    let positions = [Position(instrument: bhp, quantity: -10)]
    let service = FakeConversionService.fixedRates([bhp.id: Decimal(40)])
    let valuator = PositionsValuator(conversionService: service)
    let rows = await valuator.valuate(
      positions: positions, hostCurrency: aud, costBasis: [:], on: Date())
    let row = try #require(rows.first)
    #expect(row.value == InstrumentAmount(quantity: -400, instrument: aud))
    #expect(row.unitPrice == InstrumentAmount(quantity: 40, instrument: aud))
  }
}
