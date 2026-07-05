import Foundation
import GRDB

// Investment-trade-ready seed helpers for `UITestSeedHydrator`.
//
// Seeds a CloudKit-backed AUD profile with one `.investment` account whose
// `valuationMode` is `.calculatedFromTrades`. Two buy trades produce a net
// 30 VGS.AX position (non-host holding), which triggers both the Increment-4
// `AccountDetailView(alwaysShowsFullSurface: true)` routing and the macOS
// pinned-positions layout (`hasNonHostHoldings == true`).
//
// Additive — does not touch any existing seed or account. Split into its own
// file (mirroring `+TradeReady` / `+WalletHeader`) so the core
// `UITestSeedHydrator` enum body stays under SwiftLint's `type_body_length`.
extension UITestSeedHydrator {
  static func hydrateInvestmentTradeReady(
    into manager: ProfileContainerManager
  ) throws -> Profile {
    let fixtures = UITestFixtures.InvestmentTradeReady.self

    let profile = Profile(
      id: fixtures.profileId,
      label: fixtures.profileLabel,
      currencyCode: fixtures.profileCurrencyCode,
      financialYearStartMonth: 7,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    try upsertProfile(profile, into: manager)

    let database = try manager.database(for: profile.id)
    let audInstrument = profile.instrument
    let vgsax = Instrument.stock(
      ticker: fixtures.vgsaxTicker,
      exchange: fixtures.vgsaxExchange,
      name: fixtures.vgsaxName)

    // Register both instruments in the shared profile-index registry so any
    // leg that fans a domain `Instrument` out of them can resolve them.
    // (Fiat is ambient via the ISO fallback, but registering keeps the seed
    // explicit and consistent with other trade seeds.)
    try manager.profileIndexDatabase.write { indexDatabase in
      try upsertInstrument(vgsax, in: indexDatabase)
      try upsertInstrument(audInstrument, in: indexDatabase)
    }

    try database.write { profileDatabase in
      // Investment account: type `.investment`, valuationMode
      // `.calculatedFromTrades`. This is the account type that exercises the
      // Increment-4 `AccountDetailView(alwaysShowsFullSurface: true)` dispatch.
      try upsertAccount(
        AccountSpec(
          id: fixtures.portfolioAccountId,
          name: fixtures.portfolioAccountName,
          type: .investment,
          instrumentId: audInstrument.id,
          position: 0,
          valuationMode: .calculatedFromTrades),
        in: profileDatabase)

      try seedInvestmentTradeReadyTrades(
        accountId: fixtures.portfolioAccountId,
        audInstrument: audInstrument,
        vgsax: vgsax,
        in: profileDatabase)
    }
    return profile
  }

  /// Input bundle for a single pair-leg buy trade (no fee).
  /// Keeps `insertInvestmentTrade(_:in:)` within SwiftLint's
  /// `function_parameter_count` limit (≤ 5).
  struct InvestmentTradeSpec {
    let id: UUID
    let date: Date
    let accountId: UUID
    let paid: (instrument: Instrument, quantity: Decimal)
    let received: (instrument: Instrument, quantity: Decimal)
  }

  /// Seeds two buy transactions on the portfolio account:
  ///   - 14-Apr-26: −$300 AUD → +20 VGS.AX.
  ///   - 21-Apr-26: −$160 AUD → +10 VGS.AX.
  /// The net 30 VGS.AX position makes
  /// `AccountDetailLayout.hasNonHostHoldings == true` (VGS.AX is non-host)
  /// and ensures `computePerformance` returns a non-nil `AccountPerformance`
  /// so `showsPerformanceTiles` evaluates to `true` on the Chart pane.
  private static func seedInvestmentTradeReadyTrades(
    accountId: UUID,
    audInstrument: Instrument,
    vgsax: Instrument,
    in database: Database
  ) throws {
    let day: TimeInterval = 86_400
    // 14-Apr-26 00:00:00 UTC — matches the `tradeReady` base date for
    // consistency across trade-oriented seeds.
    let base = Date(timeIntervalSince1970: 1_776_000_000)
    let fixtures = UITestFixtures.InvestmentTradeReady.self

    try insertInvestmentTrade(
      InvestmentTradeSpec(
        id: fixtures.trade1Id,
        date: base,
        accountId: accountId,
        paid: (audInstrument, -300),
        received: (vgsax, 20)),
      in: database)

    try insertInvestmentTrade(
      InvestmentTradeSpec(
        id: fixtures.trade2Id,
        date: base.addingTimeInterval(7 * day),
        accountId: accountId,
        paid: (audInstrument, -160),
        received: (vgsax, 10)),
      in: database)
  }

  /// Inserts a `.trade` transaction with two paired `.trade` legs
  /// (paid + received). No fee leg — the minimal structure needed to
  /// create a non-host position and P&L history for the account.
  /// Idempotent via the parent-existence guard.
  private static func insertInvestmentTrade(
    _ spec: InvestmentTradeSpec,
    in database: Database
  ) throws {
    if try TransactionRow.fetchOne(database, key: spec.id) != nil { return }

    let txn = Transaction(id: spec.id, date: spec.date, payee: nil, legs: [])
    try TransactionRow(domain: txn).insert(database)

    let paidLeg = TransactionLeg(
      accountId: spec.accountId,
      instrument: spec.paid.instrument,
      quantity: spec.paid.quantity,
      type: .trade)
    let receivedLeg = TransactionLeg(
      accountId: spec.accountId,
      instrument: spec.received.instrument,
      quantity: spec.received.quantity,
      type: .trade)
    try TransactionLegRow(domain: paidLeg, transactionId: spec.id, sortOrder: 0)
      .insert(database)
    try TransactionLegRow(domain: receivedLeg, transactionId: spec.id, sortOrder: 1)
      .insert(database)
  }
}
