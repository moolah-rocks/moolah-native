import Foundation
import Testing

@testable import Moolah

/// Additional coverage for `MultiInstrumentPositionsAssembler` and
/// `PositionsHistoryBuilder` that did not fit in the existing test files
/// without exceeding the SwiftLint `type_body_length` limit.
@Suite("MultiInstrumentPositions coverage")
struct MultiInstrumentPositionsCoverageTests {
  let aud = Instrument.AUD
  let usd = Instrument.USD
  let btc = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8)
  // ETH uses a distinct contractAddress so its id "1:0x…0eee" differs from
  // BTC's "1:native" — avoids id collision in any [instrumentId: …] dict.
  let eth = Instrument.crypto(
    chainId: 1,
    contractAddress: "0x0000000000000000000000000000000000000eee",
    symbol: "ETH", name: "Ethereum", decimals: 18)
  let accountA = UUID()
  let accountB = UUID()

  /// Day 0 = 2026-01-01 UTC midnight. Uses `Calendar.utc` for zone-invariant results.
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

  // MARK: - (a) Multi-account group contributions

  // An INTERNAL transfer (touching ≥2 members of accountIds) is EXCLUDED from
  // group contributions; an EXTERNAL inflow into exactly one member IS counted.
  // Asserts the aggregate `contributions` at the last emitted point reflects
  // only the external inflow, not the internal transfer.
  @Test("internal transfer excluded from contributions; external inflow counted")
  func groupContributionsExcludesInternalTransfer() async throws {
    let externalSource = UUID()  // outside the group

    // Day 1: Account A buys BTC (external — only accountA touched).
    let buyTxn = Transaction(
      date: date(daysAfterEpoch: 1),
      legs: [
        TransactionLeg(accountId: accountA, instrument: btc, quantity: 2, type: .trade),
        TransactionLeg(accountId: accountA, instrument: aud, quantity: -40_000, type: .trade),
      ]
    )
    // Day 2: External AUD inflow to accountA (external counterpart = externalSource).
    let externalInflow = Transaction(
      date: date(daysAfterEpoch: 2),
      legs: [
        TransactionLeg(accountId: accountA, instrument: aud, quantity: 5_000, type: .income),
        TransactionLeg(
          accountId: externalSource, instrument: aud, quantity: -5_000, type: .expense),
      ]
    )
    // Day 3: Internal BTC transfer from accountA to accountB (both in group).
    // Must be excluded from contributions.
    let internalTransfer = Transaction(
      date: date(daysAfterEpoch: 3),
      legs: [
        TransactionLeg(accountId: accountA, instrument: btc, quantity: -1, type: .expense),
        TransactionLeg(accountId: accountB, instrument: btc, quantity: 1, type: .income),
      ]
    )

    let service = FakeConversionService.fixedRates([btc.id: Decimal(20_000)])
    let builder = PositionsHistoryBuilder(conversionService: service)
    let now = date(daysAfterEpoch: 5)
    let series = await builder.build(
      transactions: [buyTxn, externalInflow, internalTransfer],
      accountIds: Set([accountA, accountB]),
      hostCurrency: aud,
      range: .threeMonths,
      now: now
    )

    // At least one aggregate point must emit (the group holds BTC from day 1).
    let lastPoint = try #require(series.totalSeries.last)
    // `AccountCashFlows.flowAmounts` counts a leg only when the transaction
    // crosses a boundary (touches a second distinct accountId) OR the leg is
    // an openingBalance. The buy has both legs on accountA only (crossesBoundary
    // = false, no openingBalance) → contributes 0. The external inflow crosses
    // the boundary (externalSource leg) → accountA's +5_000 AUD income leg
    // qualifies. The internal transfer is excluded before reaching flowAmounts
    // (≥2 group members touched → the group-level guard skips it entirely).
    // Total expected contributions = 0 + 5_000 + 0 = 5_000.
    #expect(lastPoint.contributions == 5_000)
  }

  // MARK: - (b) Partial price history — aggregate omits failed days; per-instrument keeps them

  // When one token's price is permanently unavailable, the aggregate `total`
  // series is suppressed on every day that token is held (all points are omitted
  // once ETH enters the portfolio), while the per-instrument series for a
  // fully-priced token (BTC) still charts those same days.
  //
  // `FakeConversionService.failingInstruments` marks ETH as permanently
  // unavailable so no
  // aggregate point ever emits after day 2 (when ETH is bought). BTC is
  // unaffected and produces a full per-instrument series for all days.
  @Test("partial price failure: aggregate suppressed; fully-priced instrument keeps all days")
  func partialPriceHistoryAggregateIsSparse() async {
    // Day 1: BTC bought (only BTC held — aggregate can emit on day 1).
    // Day 2: ETH bought (now both held — ETH conversion always fails → no
    //         aggregate on day 2 onwards; BTC per-instrument still emits).
    let txns = [
      Transaction(
        date: date(daysAfterEpoch: 1),
        legs: [
          TransactionLeg(accountId: accountA, instrument: btc, quantity: 1, type: .trade),
          TransactionLeg(accountId: accountA, instrument: aud, quantity: -20_000, type: .trade),
        ]
      ),
      Transaction(
        date: date(daysAfterEpoch: 2),
        legs: [
          TransactionLeg(accountId: accountA, instrument: eth, quantity: 10, type: .trade),
          TransactionLeg(accountId: accountA, instrument: aud, quantity: -15_000, type: .trade),
        ]
      ),
    ]
    // ETH conversion always fails; BTC converts at a fixed rate.
    let service = FakeConversionService.failingInstruments(
      [eth.id],
      rates: [btc.id: Decimal(20_000)]
    )
    let builder = PositionsHistoryBuilder(conversionService: service)
    let now = date(daysAfterEpoch: 4)
    let series = await builder.build(
      transactions: txns,
      accountId: accountA,
      hostCurrency: aud,
      range: .threeMonths,
      now: now
    )

    // Day 1: only BTC held, BTC converts → aggregate emits.
    let day1 = date(daysAfterEpoch: 1)
    let aggregateDates = series.totalSeries.map { Calendar.utc.startOfDay(for: $0.date) }
    #expect(aggregateDates.contains(day1), "day 1 aggregate must be present (BTC only)")

    // Day 2 onwards: ETH is held and always fails → aggregate omits those days.
    let day2 = date(daysAfterEpoch: 2)
    let day3 = date(daysAfterEpoch: 3)
    let day4 = date(daysAfterEpoch: 4)
    #expect(!aggregateDates.contains(day2), "day 2 aggregate must be absent (ETH failure)")
    #expect(!aggregateDates.contains(day3), "day 3 aggregate must be absent (ETH failure)")
    #expect(!aggregateDates.contains(day4), "day 4 aggregate must be absent (ETH failure)")

    // BTC per-instrument series covers all 4 days (BTC conversion never fails).
    let btcSeries = series.series(forInstrumentIds: [btc.id])
    #expect(btcSeries.count == 4, "BTC series should have 4 points (days 1–4)")
  }

  // MARK: - (c) Transfer-only token: value-only chart, end-to-end

  /// Constructs a noon-UTC `Date` for the given year/month/day.
  private func noonUTC(year: Int, month: Int, day: Int) throws -> Date {
    var comps = DateComponents()
    comps.year = year
    comps.month = month
    comps.day = day
    comps.hour = 12
    return try #require(Calendar.utc.date(from: comps))
  }

  // A crypto account holding a token acquired ONLY via a transfer-in (cost
  // basis is nil — no trade leg) with daily prices should yield:
  //   showsChart == true  (historical value series has points)
  //   showsPLPill == false (no cost-bearing position → no gain/loss pill)
  @Test("transfer-only token: showsChart true, showsPLPill false")
  func transferOnlyTokenValueOnlyChart() async throws {
    let (backend, _) = try TestBackend.create(instrument: aud)
    try await TestBackend.register(btc, in: backend)

    let accountId = UUID()
    let account = Account(id: accountId, name: "BTC Wallet", type: .investment, instrument: aud)
    _ = try await backend.accounts.create(
      account, openingBalance: InstrumentAmount(quantity: 0, instrument: aud))

    // Acquire BTC via a transfer-in (income leg) — no fiat trade leg, so the
    // cost basis classifier sees no buy event and leaves costBasis nil.
    let transferIn = Transaction(
      date: try noonUTC(year: 2026, month: 5, day: 10),
      legs: [
        TransactionLeg(accountId: accountId, instrument: btc, quantity: 2, type: .income),
        TransactionLeg(accountId: UUID(), instrument: btc, quantity: -2, type: .expense),
      ]
    )
    _ = try await backend.transactions.create(transferIn)

    let rate: Decimal = 30_000
    let conversionService = FakeConversionService.fixedRates([btc.id: rate])
    let assembler = MultiInstrumentPositionsAssembler(conversionService: conversionService)
    let transactions = try await assembler.fetchTransactions(
      repository: backend.transactions, accountIds: [accountId])
    #expect(transactions.count == 1)

    let qty: Decimal = 2
    let valuedRows = [
      ValuedPosition(
        instrument: btc, quantity: qty,
        unitPrice: InstrumentAmount(quantity: rate, instrument: aud),
        costBasis: nil,
        value: InstrumentAmount(quantity: qty * rate, instrument: aud))
    ]
    let context = PositionsAssemblyContext(
      title: "BTC Wallet", hostCurrency: aud, accountIds: [accountId])
    let input = await assembler.assemble(
      context: context, valuedRows: valuedRows, transactions: transactions,
      range: .threeMonths, now: try noonUTC(year: 2026, month: 5, day: 15))

    // The value series must have points — chart renders value even without cost basis.
    let series = try #require(input.historicalValue, "historicalValue must be non-nil")
    #expect(!series.total.isEmpty, "total series must not be empty")
    #expect(input.showsChart, "showsChart must be true: historical value exists")
    // No position has a cost basis, so the P&L pill must not appear.
    #expect(!input.showsPLPill, "showsPLPill must be false: no cost-bearing position")
  }

  // MARK: - (d) Mixed-instrument group: aggregate converts to group host

  // Two accounts each holding a different crypto instrument. The group's
  // `hostCurrency` is AUD. The last-day aggregate value must equal the sum
  // of each holding converted to AUD at the fixed per-instrument rate.
  // Income (receive-only) legs are used so no host-currency cost leg is
  // introduced — the test pins pure position value, not cost-adjusted balance.
  @Test("mixed-instrument group: aggregate last-day value equals sum converted to host")
  func mixedInstrumentGroupAggregatesInHostCurrency() async throws {
    let qtyBtc: Decimal = 1
    let qtyEth: Decimal = 5
    let rateBtc: Decimal = 50_000
    let rateEth: Decimal = 3_000
    let externalA = UUID()
    let externalB = UUID()

    let txns = [
      Transaction(
        date: date(daysAfterEpoch: 1),
        legs: [
          TransactionLeg(accountId: accountA, instrument: btc, quantity: qtyBtc, type: .income),
          TransactionLeg(accountId: externalA, instrument: btc, quantity: -qtyBtc, type: .expense),
        ]
      ),
      Transaction(
        date: date(daysAfterEpoch: 1),
        legs: [
          TransactionLeg(accountId: accountB, instrument: eth, quantity: qtyEth, type: .income),
          TransactionLeg(accountId: externalB, instrument: eth, quantity: -qtyEth, type: .expense),
        ]
      ),
    ]
    let service = FakeConversionService.fixedRates([
      btc.id: rateBtc,
      eth.id: rateEth,
    ])
    let builder = PositionsHistoryBuilder(conversionService: service)
    let now = date(daysAfterEpoch: 3)
    let series = await builder.build(
      transactions: txns,
      accountIds: Set([accountA, accountB]),
      hostCurrency: aud,
      range: .threeMonths,
      now: now
    )

    let lastPoint = try #require(series.totalSeries.last)
    let expectedValue = qtyBtc * rateBtc + qtyEth * rateEth
    #expect(lastPoint.value == expectedValue)
  }
}
