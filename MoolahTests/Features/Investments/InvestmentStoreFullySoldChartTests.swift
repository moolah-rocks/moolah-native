import Foundation
import Testing

@testable import Moolah

@MainActor
@Suite("InvestmentStore fully-sold account chart")
struct InvestmentStoreFullySoldChartTests {
  let aud = Instrument.AUD
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")

  // Fixed historical anchor dates so the suite is independent of the
  // wall-clock. `PositionsTimeRange.all` is used at the call site so the
  // history builder doesn't filter these out.
  let buyDate = Date(timeIntervalSinceReferenceDate: 599_616_000)  // 2020-01-01
  let sellDate = Date(timeIntervalSinceReferenceDate: 601_430_400)  // 2020-01-21

  /// Builds a position-tracked account that bought then fully sold 100
  /// BHP (a buy @ 40 AUD then sell-all @ 50 AUD, both in 2020). Returns
  /// the store + account ready for a `loadAndBuildPositionsInput` call.
  private func makeFullySoldAccount() async throws -> (InvestmentStore, Account) {
    let (backend, _) = try TestBackend.create()
    let conversionService = FakeConversionService.fixedRates([bhp.id: Decimal(50)])
    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: conversionService
    )
    let account = Account(
      name: "Brokerage", type: .investment, instrument: aud,
      valuationMode: .calculatedFromTrades)
    _ = try await backend.accounts.create(
      account, openingBalance: InstrumentAmount(quantity: 0, instrument: aud))
    _ = try await backend.transactions.create(
      Transaction(
        date: buyDate,
        legs: [
          TransactionLeg(accountId: account.id, instrument: bhp, quantity: 100, type: .trade),
          TransactionLeg(accountId: account.id, instrument: aud, quantity: -4_000, type: .trade),
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: sellDate,
        legs: [
          TransactionLeg(accountId: account.id, instrument: bhp, quantity: -100, type: .trade),
          TransactionLeg(accountId: account.id, instrument: aud, quantity: 5_000, type: .trade),
        ]))
    return (store, account)
  }

  @Test("fully-sold account still surfaces the historical chart")
  func fullySoldAccountSurfacesChart() async throws {
    let (store, account) = try await makeFullySoldAccount()
    let input = try await store.loadAndBuildPositionsInput(
      account: account, profileCurrency: aud, range: .all)

    // A sell-for-profit leaves the net cash leg as a host-currency
    // position; `loadPositions` keeps non-zero rows, so `shouldHide`
    // stays true even though the full surface still renders.
    let nonHostPositions = input.positions.filter { $0.instrument != aud }
    #expect(
      nonHostPositions.isEmpty,
      "sell-for-profit should leave only the host-currency cash leg in positions")
    #expect(
      input.shouldHide,
      "cash-only positions should trigger shouldHide")
    #expect(
      input.hasHistoricalSeries,
      "trade history should produce a non-empty historical series")
    #expect(
      input.showsChart,
      "chart should surface when shouldHide is true and history is non-empty")
    #expect(
      input.showsAggregateChart,
      "aggregate chart line should render when totalValue is available")
    #expect(
      input.hasAnyHistoricalActivity,
      "non-host trade legs in the transaction set should set hasAnyHistoricalActivity")
    #expect(
      input.alwaysShowsFullSurface,
      "trade-calculated investment accounts always render the full surface")
    #expect(
      !input.rendersNothing,
      "the full surface must render even though shouldHide is true")
  }

  @Test("fully-sold account reports hasAnyHistoricalActivity even on a narrow range")
  func fullySoldAccountReportsActivityOnNarrowRange() async throws {
    // Regression for the production bug: the user's last sale predates the
    // default `.threeMonths` window, so `hasHistoricalSeries` is false. The
    // view layer needs a range-independent signal to keep the chart
    // populated on a narrow range — `hasAnyHistoricalActivity`.
    let (store, account) = try await makeFullySoldAccount()
    let input = try await store.loadAndBuildPositionsInput(
      account: account, profileCurrency: aud, range: .threeMonths)

    #expect(
      input.shouldHide,
      "host-currency-only positions should still trigger shouldHide")
    #expect(
      !input.hasHistoricalSeries,
      "trades from 2020 fall outside .threeMonths so the series is empty")
    #expect(
      input.hasAnyHistoricalActivity,
      "the non-host trade legs make the account chart-worthy even on a narrow range")
    #expect(
      input.alwaysShowsFullSurface,
      "trade-calculated investment accounts always render the full surface")
    #expect(!input.rendersNothing)
  }

  @Test("empty account with no trade history hides the chart")
  func emptyAccountHidesChart() async throws {
    let (backend, _) = try TestBackend.create()
    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: backend.conversionService
    )
    let account = Account(
      name: "Brokerage", type: .investment, instrument: aud,
      valuationMode: .calculatedFromTrades)
    _ = try await backend.accounts.create(
      account, openingBalance: InstrumentAmount(quantity: 0, instrument: aud))

    let input = try await store.loadAndBuildPositionsInput(
      account: account, profileCurrency: aud, range: .threeMonths)

    #expect(input.positions.isEmpty)
    #expect(input.shouldHide)
    #expect(!input.hasHistoricalSeries)
    #expect(!input.showsChart)
    #expect(
      !input.hasAnyHistoricalActivity,
      "no transactions at all means no historical activity to surface")
    #expect(
      input.alwaysShowsFullSurface,
      "even a trade-calculated account with no trades renders the full surface")
    #expect(
      !input.rendersNothing,
      "the surface (tiles + empty table) renders for consistency")
  }
}
