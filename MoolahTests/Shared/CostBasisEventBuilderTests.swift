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

  private func holding(
    _ account: UUID?,
    taxOwnerId: UUID? = nil
  ) -> CostBasisEventHolding {
    CostBasisEventHolding(account: account, taxOwnerId: taxOwnerId)
  }

  @Test
  func fiatPairedBuy_mapsToAcquisition() async throws {
    let legs = [leg(aud, -2_000, .trade), leg(eth, 1, .trade)]
    let events = try await CostBasisEventBuilder.events(
      legs: legs, on: day, trackedAccountIds: [account], referenceCurrency: aud,
      conversionService: FakeConversionService.fixedRates([:]))
    #expect(
      events == [
        .acquisition(
          instrument: eth, quantity: 1, costPerUnit: 2_000, holding: holding(account))
      ])
  }

  @Test
  func nonFiatIncome_mapsToAcquisitionAtMarketValue() async throws {
    let legs = [leg(eth, dec("0.5"), .income)]
    let events = try await CostBasisEventBuilder.events(
      legs: legs, on: day, trackedAccountIds: [account], referenceCurrency: aud,
      conversionService: FakeConversionService.fixedRates([eth.id: 4_000]))  // 1 ETH = 4000 AUD
    #expect(
      events == [
        .acquisition(
          instrument: eth, quantity: dec("0.5"), costPerUnit: 4_000, holding: holding(account))
      ])
  }

  @Test
  func nonFiatOpeningBalance_mapsToAcquisitionAtMarketValue() async throws {
    let legs = [leg(eth, 2, .openingBalance)]
    let events = try await CostBasisEventBuilder.events(
      legs: legs, on: day, trackedAccountIds: [account], referenceCurrency: aud,
      conversionService: FakeConversionService.fixedRates([eth.id: 3_000]))
    #expect(
      events == [
        .acquisition(
          instrument: eth, quantity: 2, costPerUnit: 3_000, holding: holding(account))
      ])
  }

  @Test
  func nonFiatExpenseRefund_mapsToAcquisitionAtMarketValue() async throws {
    // A positive-quantity non-fiat `.expense` is a refund (sign convention lets
    // any type carry the opposite sign) — the mirror of the gas/spend disposal,
    // so it re-enters holdings as an acquisition at market value.
    let legs = [leg(eth, dec("0.02"), .expense)]
    let events = try await CostBasisEventBuilder.events(
      legs: legs, on: day, trackedAccountIds: [account], referenceCurrency: aud,
      conversionService: FakeConversionService.fixedRates([eth.id: 2_000]))
    #expect(
      events == [
        .acquisition(
          instrument: eth, quantity: dec("0.02"), costPerUnit: 2_000, holding: holding(account))
      ])
  }

  @Test
  func nonFiatIncome_usesTransactionDateNotToday() async throws {
    // dateRates ignores nothing: the builder must convert on the transaction
    // `day` (rate 4000), never on "today" (rate 9999). A regression that
    // substituted `Date()` for the transaction date would fail here.
    let service = FakeConversionService.dateRates([
      day: [eth.id: 4_000],
      Date(): [eth.id: 9_999],
    ])
    let events = try await CostBasisEventBuilder.events(
      legs: [leg(eth, dec("0.5"), .income)], on: day, trackedAccountIds: [account],
      referenceCurrency: aud, conversionService: service)
    #expect(
      events == [
        .acquisition(
          instrument: eth, quantity: dec("0.5"), costPerUnit: 4_000, holding: holding(account))
      ])
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
        .move(
          instrument: eth, quantity: 1,
          route: CostBasisMoveRoute(from: account, to: accountB, taxOwnerId: nil),
          marketValue: 0)
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
