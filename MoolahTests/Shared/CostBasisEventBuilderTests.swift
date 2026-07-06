import Foundation
import Testing

@testable import Moolah

@Suite("CostBasisEventBuilder")
struct CostBasisEventBuilderTests {
  private let aud = Instrument.AUD
  private let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
  private let account = UUID()
  private let day = Date(timeIntervalSince1970: 1_700_000_000)

  private func leg(_ instrument: Instrument, _ quantity: Decimal, _ type: TransactionType)
    -> TransactionLeg
  {
    TransactionLeg(accountId: account, instrument: instrument, quantity: quantity, type: type)
  }

  @Test
  func fiatPairedBuy_mapsToAcquisition() async throws {
    let legs = [leg(aud, -2_000, .trade), leg(eth, 1, .trade)]
    let events = try await CostBasisEventBuilder.events(
      legs: legs, on: day, trackedAccountIds: [account], referenceCurrency: aud,
      conversionService: FakeConversionService.fixedRates([:]))
    #expect(
      events == [.acquisition(instrument: eth, quantity: 1, costPerUnit: 2_000, account: account)])
  }

  @Test
  func nonFiatIncome_mapsToAcquisitionAtMarketValue() async throws {
    let legs = [leg(eth, dec("0.5"), .income)]
    let events = try await CostBasisEventBuilder.events(
      legs: legs, on: day, trackedAccountIds: [account], referenceCurrency: aud,
      conversionService: FakeConversionService.fixedRates([eth.id: 4_000]))  // 1 ETH = 4000 AUD
    #expect(
      events == [
        .acquisition(instrument: eth, quantity: dec("0.5"), costPerUnit: 4_000, account: account)
      ])
  }

  @Test
  func nonFiatOpeningBalance_mapsToAcquisitionAtMarketValue() async throws {
    let legs = [leg(eth, 2, .openingBalance)]
    let events = try await CostBasisEventBuilder.events(
      legs: legs, on: day, trackedAccountIds: [account], referenceCurrency: aud,
      conversionService: FakeConversionService.fixedRates([eth.id: 3_000]))
    #expect(
      events == [.acquisition(instrument: eth, quantity: 2, costPerUnit: 3_000, account: account)])
  }

  @Test
  func fiatLegs_areNonEvents() async throws {
    let legs = [leg(aud, 1_000, .income), leg(aud, -50, .expense)]
    let events = try await CostBasisEventBuilder.events(
      legs: legs, on: day, trackedAccountIds: [account], referenceCurrency: aud,
      conversionService: FakeConversionService.fixedRates([:]))
    #expect(events.isEmpty)
  }

  @Test
  func trackedTransfer_mapsToMove() async throws {
    let accountB = UUID()
    let legs = [
      TransactionLeg(accountId: account, instrument: eth, quantity: -1, type: .transfer),
      TransactionLeg(accountId: accountB, instrument: eth, quantity: 1, type: .transfer),
    ]
    let events = try await CostBasisEventBuilder.events(
      legs: legs, on: day, trackedAccountIds: [account, accountB], referenceCurrency: aud,
      conversionService: FakeConversionService.fixedRates([eth.id: 5_000]))
    #expect(
      events == [
        .move(instrument: eth, quantity: 1, from: account, to: accountB, marketValue: 5_000)
      ])
  }

  @Test
  func cryptoGasFeeOnSwap_disposesFeeAssetAndFoldsIntoBuyCost() async throws {
    // Swap AUD->ETH with a small ETH gas fee attached: buy ETH (fee folded into
    // cost via classifier) AND dispose the ETH gas leg at market value.
    let legs = [
      leg(aud, -2_000, .trade), leg(eth, 1, .trade), leg(eth, dec("-0.01"), .expense),
    ]
    let events = try await CostBasisEventBuilder.events(
      legs: legs, on: day, trackedAccountIds: [account], referenceCurrency: aud,
      conversionService: FakeConversionService.fixedRates([eth.id: 2_000]))
    // One acquisition (ETH bought) + one disposal (ETH gas consumed).
    #expect(
      events.contains {
        if case let .acquisition(instrument, _, _, _) = $0 { return instrument == eth }
        return false
      })
    #expect(
      events.contains {
        if case let .disposal(instrument, quantity, _, _) = $0 {
          return instrument == eth && quantity == dec("0.01")
        }
        return false
      })
  }
}
