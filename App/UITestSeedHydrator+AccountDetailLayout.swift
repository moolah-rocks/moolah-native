import Foundation
import GRDB

// Account-detail-layout seed helpers for `UITestSeedHydrator`.
//
// Seeds a CloudKit-backed AUD profile with two bank accounts:
//   - "Multi-Currency" — AUD denomination + a USD income leg, creating a
//     non-host position so `AccountDetailLayout.hasNonHostHoldings` returns
//     `true` and the macOS layout pins the Positions pane.
//   - "Everyday" — AUD denomination, AUD-only legs; no non-host positions
//     so the macOS layout renders a single toggle pane.
// Each account carries 2–3 deterministic transactions so the transaction
// list and balance chart both have data.
//
// Split into its own file (mirroring the `+GroupFilterScope` /
// `+WalletHeader` split) so the core `UITestSeedHydrator` enum body
// stays under SwiftLint's `type_body_length` threshold.
extension UITestSeedHydrator {
  /// Input bundle for a single-leg income transaction. Mirrors the
  /// `HistoricalExpenseSpec` pattern so the income helper stays under
  /// SwiftLint's `function_parameter_count` threshold (≤ 5).
  struct AccountDetailIncomeSpec {
    let id: UUID
    let payee: String
    let date: Date
    let amount: InstrumentAmount
    let accountId: UUID
  }

  static func hydrateAccountDetailLayout(
    into manager: ProfileContainerManager
  ) throws -> Profile {
    let fixtures = UITestFixtures.AccountDetailLayout.self

    let profile = Profile(
      id: fixtures.profileId,
      label: fixtures.profileLabel,
      currencyCode: fixtures.profileCurrencyCode,
      financialYearStartMonth: 7,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    try upsertProfile(profile, into: manager)

    let database = try manager.database(for: profile.id)
    let instrument = profile.instrument

    // Instrument identity lives on the shared profile-index registry.
    // Register AUD (the profile denomination) and USD before any leg fans
    // a domain `Instrument` out of them. Mirrors the pattern in
    // `hydrateTradeBaseline` which also registers USD for cross-currency
    // scenarios.
    try manager.profileIndexDatabase.write { indexDatabase in
      try upsertInstrument(instrument, in: indexDatabase)
      try upsertInstrument(.USD, in: indexDatabase)
    }

    try database.write { profileDatabase in
      try seedAccountDetailLayoutAccounts(instrument: instrument, in: profileDatabase)
      try seedMultiCurrencyTransactions(instrument: instrument, in: profileDatabase)
      try seedEverydayFiatTransactions(instrument: instrument, in: profileDatabase)
    }
    return profile
  }

  private static func seedAccountDetailLayoutAccounts(
    instrument: Instrument, in database: Database
  ) throws {
    let fixtures = UITestFixtures.AccountDetailLayout.self
    // Multi-currency bank account (AUD denomination). Transaction legs
    // in both AUD and USD create the non-host USD position that triggers
    // the macOS pinned-positions layout.
    try upsertAccount(
      AccountSpec(
        id: fixtures.multiCurrencyAccountId,
        name: fixtures.multiCurrencyAccountName,
        type: .bank,
        instrumentId: instrument.id,
        position: 0),
      in: database)
    // Everyday fiat account (AUD denomination). Only AUD legs — no
    // non-host positions, so the macOS layout renders a single toggle pane.
    try upsertAccount(
      AccountSpec(
        id: fixtures.everydayAccountId,
        name: fixtures.everydayAccountName,
        type: .bank,
        instrumentId: instrument.id,
        position: 1),
      in: database)
  }

  /// Seeds the three deterministic transactions for the multi-currency account:
  /// AUD income (opening balance), AUD expense (supermarket), and USD income
  /// (foreign transfer). The USD income leg creates the non-host position.
  private static func seedMultiCurrencyTransactions(
    instrument: Instrument, in database: Database
  ) throws {
    let fixtures = UITestFixtures.AccountDetailLayout.self
    let accountId = fixtures.multiCurrencyAccountId

    try seedAccountDetailIncome(
      AccountDetailIncomeSpec(
        id: fixtures.multiCurrencyTxn1Id,
        payee: fixtures.multiCurrencyTxn1Payee,
        date: fixtures.multiCurrencyTxn1Date,
        amount: InstrumentAmount(
          quantity: Decimal(fixtures.multiCurrencyTxn1Cents) / 100,
          instrument: instrument),
        accountId: accountId),
      in: database)

    try upsertHistoricalExpense(
      HistoricalExpenseSpec(
        id: fixtures.multiCurrencyTxn2Id,
        payee: fixtures.multiCurrencyTxn2Payee,
        date: fixtures.multiCurrencyTxn2Date,
        amount: InstrumentAmount(
          quantity: Decimal(fixtures.multiCurrencyTxn2Cents) / 100,
          instrument: instrument),
        accountId: accountId,
        categoryId: nil),
      in: database)

    // USD income: the leg's instrument_id = "USD" on the AUD account
    // creates the non-host position that makes
    // `AccountDetailLayout.hasNonHostHoldings` return `true`.
    try seedAccountDetailIncome(
      AccountDetailIncomeSpec(
        id: fixtures.multiCurrencyTxn3Id,
        payee: fixtures.multiCurrencyTxn3Payee,
        date: fixtures.multiCurrencyTxn3Date,
        amount: InstrumentAmount(
          quantity: Decimal(fixtures.multiCurrencyTxn3Cents) / 100,
          instrument: .USD),
        accountId: accountId),
      in: database)
  }

  /// Seeds the three deterministic transactions for the everyday fiat account:
  /// AUD salary income, AUD rent expense, AUD groceries expense.
  private static func seedEverydayFiatTransactions(
    instrument: Instrument, in database: Database
  ) throws {
    let fixtures = UITestFixtures.AccountDetailLayout.self
    let accountId = fixtures.everydayAccountId

    try seedAccountDetailIncome(
      AccountDetailIncomeSpec(
        id: fixtures.everydayTxn1Id,
        payee: fixtures.everydayTxn1Payee,
        date: fixtures.everydayTxn1Date,
        amount: InstrumentAmount(
          quantity: Decimal(fixtures.everydayTxn1Cents) / 100,
          instrument: instrument),
        accountId: accountId),
      in: database)

    try upsertHistoricalExpense(
      HistoricalExpenseSpec(
        id: fixtures.everydayTxn2Id,
        payee: fixtures.everydayTxn2Payee,
        date: fixtures.everydayTxn2Date,
        amount: InstrumentAmount(
          quantity: Decimal(fixtures.everydayTxn2Cents) / 100,
          instrument: instrument),
        accountId: accountId,
        categoryId: nil),
      in: database)

    try upsertHistoricalExpense(
      HistoricalExpenseSpec(
        id: fixtures.everydayTxn3Id,
        payee: fixtures.everydayTxn3Payee,
        date: fixtures.everydayTxn3Date,
        amount: InstrumentAmount(
          quantity: Decimal(fixtures.everydayTxn3Cents) / 100,
          instrument: instrument),
        accountId: accountId,
        categoryId: nil),
      in: database)
  }

  /// Inserts a single-leg income transaction on the given account. The leg
  /// carries a positive quantity (inflow) and `.income` type. Idempotent:
  /// if the transaction id already exists the helper returns early.
  ///
  /// Named with the `AccountDetail` prefix to avoid shadowing any future
  /// income helper added to the shared `+Upserts` file.
  private static func seedAccountDetailIncome(
    _ spec: AccountDetailIncomeSpec,
    in database: Database
  ) throws {
    if try TransactionRow.fetchOne(database, key: spec.id) != nil { return }
    let txn = Transaction(id: spec.id, date: spec.date, payee: spec.payee, legs: [])
    try TransactionRow(domain: txn).insert(database)
    let leg = TransactionLeg(
      accountId: spec.accountId,
      instrument: spec.amount.instrument,
      quantity: spec.amount.quantity,  // positive = income / inflow
      type: .income)
    try TransactionLegRow(domain: leg, transactionId: spec.id, sortOrder: 0).insert(database)
  }
}
