import Foundation
import Testing

@testable import Moolah

/// End-to-end tests for `MultiInstrumentPositionsAssembler` that flow through
/// a real `TestBackend` (CloudKitBackend + in-memory GRDB). These tests pin the
/// full pipeline: `fetchTransactions` from the repository → `ValuedPosition`
/// construction → `assemble` → `PositionsViewInput` assertions.
///
/// All dates use noon-UTC construction so the results are zone-invariant
/// regardless of the CI runner's local timezone.
@Suite("MultiInstrumentPositionsAssembler end-to-end")
struct PositionsAssemblerE2ETests {
  /// Host (reporting) currency.
  let aud = Instrument.AUD
  /// Crypto token — chainId 1, id "1:native". This suite tests single-account
  /// or same-token-group scenarios; ETH is absent here so the id "1:native" is
  /// unambiguous. Tests that mix BTC and ETH must give ETH a distinct
  /// contractAddress so the two ids don't collide in instrument dictionaries.
  let btc = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8)

  /// A fixed "now" anchored at noon UTC on 2026-06-01. All date helpers and
  /// `assemble(…, now:)` calls use this value so the tests are deterministic
  /// regardless of the CI runner's local timezone or wall-clock date.
  private let fixedNow: Date = {
    var components = DateComponents()
    components.year = 2026
    components.month = 6
    components.day = 1
    components.hour = 12
    components.minute = 0
    components.second = 0
    guard let date = Calendar.utc.date(from: components) else {
      fatalError("Could not construct fixedNow")
    }
    return date
  }()

  /// Returns a Date at noon UTC, N days before `fixedNow`.
  ///
  /// Noon UTC matches the canonical day-token used throughout the codebase
  /// (`FinancialMonth.date(forKey:)` anchors at noon UTC) and ensures
  /// `Calendar.startOfDay` groups the transaction under the expected day
  /// regardless of the host machine's local timezone.
  private func noonUTCDaysAgo(_ n: Int) -> Date {
    let startOfFixedNow = Calendar.utc.startOfDay(for: fixedNow)
    guard let offset = Calendar.utc.date(byAdding: .day, value: -n, to: startOfFixedNow) else {
      fatalError("Could not offset date by \(-n) days")
    }
    return offset.addingTimeInterval(12 * 3600)
  }

  /// A fiat-paired buy transaction for one account.
  private func buy(
    instrument: Instrument,
    qty: Decimal,
    fiat: Decimal,
    accountId: UUID,
    daysAgo: Int
  ) -> Transaction {
    Transaction(
      date: noonUTCDaysAgo(daysAgo),
      legs: [
        TransactionLeg(accountId: accountId, instrument: instrument, quantity: qty, type: .trade),
        TransactionLeg(accountId: accountId, instrument: aud, quantity: -fiat, type: .trade),
      ]
    )
  }

  /// Create an investment account and seed it into the backend.
  private func createAccount(
    name: String,
    in backend: CloudKitBackend
  ) async throws -> UUID {
    let id = UUID()
    let account = Account(id: id, name: name, type: .investment, instrument: aud)
    _ = try await backend.accounts.create(
      account, openingBalance: InstrumentAmount(quantity: 0, instrument: aud))
    return id
  }

  /// Build `[ValuedPosition]` for a single crypto holding at a fixed unit rate.
  private func singlePosition(
    instrument: Instrument,
    qty: Decimal,
    rate: Decimal
  ) -> [ValuedPosition] {
    [
      ValuedPosition(
        instrument: instrument,
        quantity: qty,
        unitPrice: InstrumentAmount(quantity: rate, instrument: aud),
        costBasis: nil,
        value: InstrumentAmount(quantity: qty * rate, instrument: aud)
      )
    ]
  }

  // MARK: - Test 1: single account via backend round-trip

  /// A single crypto account holding BTC. Transactions are created via
  /// `backend.transactions.create`, then fetched through
  /// `assembler.fetchTransactions` — exercising the full repository round-trip.
  /// Asserts: the last point's value equals qty × rate (exact), showsChart == true.
  @Test("single crypto account: fetchTransactions + assemble yields non-empty chart")
  func singleCryptoAccountEndToEnd() async throws {
    let (backend, _) = try TestBackend.create(instrument: aud)
    try await TestBackend.register(btc, in: backend)
    let accountId = try await createAccount(name: "BTC Wallet", in: backend)

    let qty: Decimal = 2
    let rate: Decimal = 50_000
    _ = try await backend.transactions.create(
      buy(instrument: btc, qty: qty, fiat: 80_000, accountId: accountId, daysAgo: 5))

    let conversionService = FixedConversionService(rates: [btc.id: rate])
    let assembler = MultiInstrumentPositionsAssembler(conversionService: conversionService)
    let transactions = try await assembler.fetchTransactions(
      repository: backend.transactions, accountIds: [accountId])
    #expect(transactions.count == 1)

    let context = PositionsAssemblyContext(
      title: "BTC Wallet", hostCurrency: aud, accountIds: [accountId])
    let input = await assembler.assemble(
      context: context,
      valuedRows: singlePosition(instrument: btc, qty: qty, rate: rate),
      transactions: transactions,
      range: .threeMonths,
      now: fixedNow
    )

    let series = try #require(input.historicalValue, "historicalValue must be non-nil")
    #expect(!series.total.isEmpty, "total series must not be empty")
    let lastPoint = try #require(series.total.last)
    // FixedConversionService returns the same rate on every date.
    #expect(lastPoint.value == qty * rate)
    #expect(input.showsChart)
  }

  // MARK: - Test 2: group of two accounts holding the same token

  /// Two accounts each hold BTC. The group's last-day aggregate value
  /// must equal the summed holdings converted at the fixed rate.
  @Test("group of two accounts: aggregate last-day value equals summed holdings")
  func groupTwoAccountsAggregatesValue() async throws {
    let (backend, _) = try TestBackend.create(instrument: aud)
    try await TestBackend.register(btc, in: backend)
    let accountAId = try await createAccount(name: "Wallet A", in: backend)
    let accountBId = try await createAccount(name: "Wallet B", in: backend)

    let qtyA: Decimal = 1
    let qtyB: Decimal = 3
    let rate: Decimal = 60_000
    _ = try await backend.transactions.create(
      buy(instrument: btc, qty: qtyA, fiat: 40_000, accountId: accountAId, daysAgo: 5))
    _ = try await backend.transactions.create(
      buy(instrument: btc, qty: qtyB, fiat: 120_000, accountId: accountBId, daysAgo: 5))

    let conversionService = FixedConversionService(rates: [btc.id: rate])
    let assembler = MultiInstrumentPositionsAssembler(conversionService: conversionService)
    let accountIds: Set<UUID> = [accountAId, accountBId]
    let transactions = try await assembler.fetchTransactions(
      repository: backend.transactions, accountIds: accountIds)
    #expect(transactions.count == 2)

    let totalQty = qtyA + qtyB
    let context = PositionsAssemblyContext(
      title: "BTC Group", hostCurrency: aud, accountIds: accountIds)
    let input = await assembler.assemble(
      context: context,
      valuedRows: singlePosition(instrument: btc, qty: totalQty, rate: rate),
      transactions: transactions,
      range: .threeMonths,
      now: fixedNow
    )

    let series = try #require(input.historicalValue, "historicalValue must be non-nil")
    #expect(!series.total.isEmpty)
    let lastPoint = try #require(series.total.last)
    #expect(lastPoint.value == (qtyA + qtyB) * rate)
    #expect(input.showsChart)
  }

  // MARK: - Test 3: internal transfer between group members does not change aggregate

  /// Account A buys 2 BTC, then transfers 1 BTC to Account B (both in group).
  /// The group's last-day aggregate value stays equal to 2 BTC × rate — the
  /// internal transfer nets out on every point in the series.
  @Test("internal transfer between group members: group value unchanged after transfer")
  func internalTransferNetsOut() async throws {
    let (backend, _) = try TestBackend.create(instrument: aud)
    try await TestBackend.register(btc, in: backend)
    let accountAId = try await createAccount(name: "Sender", in: backend)
    let accountBId = try await createAccount(name: "Receiver", in: backend)

    let totalQty: Decimal = 2
    let transferQty: Decimal = 1
    let rate: Decimal = 55_000
    _ = try await backend.transactions.create(
      buy(instrument: btc, qty: totalQty, fiat: 90_000, accountId: accountAId, daysAgo: 7))
    _ = try await backend.transactions.create(
      Transaction(
        date: noonUTCDaysAgo(3),
        legs: [
          TransactionLeg(
            accountId: accountAId, instrument: btc, quantity: -transferQty, type: .expense),
          TransactionLeg(
            accountId: accountBId, instrument: btc, quantity: transferQty, type: .income),
        ]
      )
    )

    let conversionService = FixedConversionService(rates: [btc.id: rate])
    let assembler = MultiInstrumentPositionsAssembler(conversionService: conversionService)
    let accountIds: Set<UUID> = [accountAId, accountBId]
    let transactions = try await assembler.fetchTransactions(
      repository: backend.transactions, accountIds: accountIds)
    #expect(transactions.count == 2)

    let context = PositionsAssemblyContext(
      title: "BTC Transfer Group", hostCurrency: aud, accountIds: accountIds)
    let input = await assembler.assemble(
      context: context,
      valuedRows: singlePosition(instrument: btc, qty: totalQty, rate: rate),
      transactions: transactions,
      range: .threeMonths,
      now: fixedNow
    )

    let series = try #require(input.historicalValue, "historicalValue must be non-nil")
    #expect(!series.total.isEmpty)
    let lastPoint = try #require(series.total.last)
    // Internal transfer nets out — group holds 2 BTC externally on every day.
    #expect(lastPoint.value == totalQty * rate)
    // FixedConversionService is date-independent: every emitted point equals
    // totalQty × rate (the transfer causes no dip or phantom buy/sell).
    for point in series.total {
      #expect(point.value == totalQty * rate)
    }
    #expect(input.showsChart)
  }
}
