import Foundation
import GRDB

// Group-filter-scope seed helpers for `UITestSeedHydrator`.
//
// Seeds an AUD profile, an account group ("Filter Group") with two bank
// members plus a standalone non-member account, and one dated expense in
// each of the three accounts. Drives the end-to-end proof that applying a
// filter while viewing an account group keeps the transaction list scoped
// to the group's members. Split into its own file (mirroring the
// `+TransferDetection` / `+TradeReady` split) so the core
// `UITestSeedHydrator` enum body stays under SwiftLint's
// `type_body_length` threshold.
extension UITestSeedHydrator {
  static func hydrateGroupFilterScope(
    into manager: ProfileContainerManager
  ) throws -> Profile {
    let fixtures = UITestFixtures.GroupFilterScope.self

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

    // Instrument identity lives on the shared profile-index registry —
    // register the profile denomination before any leg fans a domain
    // `Instrument` out of it.
    try manager.profileIndexDatabase.write { database in
      try upsertInstrument(instrument, in: database)
    }

    try database.write { database in
      // Group first so the members' `group_id` back-reference resolves to
      // an existing row when the sidebar builds the group's member list.
      try seedGroupFilterScopeGroupAndAccounts(instrument: instrument, in: database)
      try seedGroupFilterScopeTransactions(instrument: instrument, in: database)
    }
    return profile
  }

  private static func seedGroupFilterScopeGroupAndAccounts(
    instrument: Instrument, in database: Database
  ) throws {
    let fixtures = UITestFixtures.GroupFilterScope.self
    try upsertAccountGroup(
      AccountGroupSpec(
        id: fixtures.filterGroupId,
        name: fixtures.filterGroupName,
        bucketRawValue: AccountBucket.current.rawValue,
        instrumentId: instrument.id,
        position: 0),
      in: database)

    // Two members carry `group_id = filterGroup`; the outsider stays
    // standalone (nil group). All three are bank / AUD so they share the
    // `current` bucket as the group.
    try upsertAccount(
      AccountSpec(
        id: fixtures.memberOneId,
        name: fixtures.memberOneName,
        type: .bank,
        instrumentId: instrument.id,
        position: 0,
        groupId: fixtures.filterGroupId),
      in: database)
    try upsertAccount(
      AccountSpec(
        id: fixtures.memberTwoId,
        name: fixtures.memberTwoName,
        type: .bank,
        instrumentId: instrument.id,
        position: 1,
        groupId: fixtures.filterGroupId),
      in: database)
    try upsertAccount(
      AccountSpec(
        id: fixtures.outsiderId,
        name: fixtures.outsiderName,
        type: .bank,
        instrumentId: instrument.id,
        position: 2),
      in: database)
  }

  /// Seeds one single-leg expense in each account. Dates are anchored a
  /// fixed number of days before launch so they all fall inside the
  /// filter dialog's default `[now − 1 month, now]` window whenever the
  /// suite runs; every UUID / payee / amount stays deterministic.
  private static func seedGroupFilterScopeTransactions(
    instrument: Instrument, in database: Database
  ) throws {
    let fixtures = UITestFixtures.GroupFilterScope.self
    let amount = InstrumentAmount(
      quantity: Decimal(fixtures.expenseAmountCents) / 100,
      instrument: instrument)
    let now = Date()
    func date(daysAgo: Int) -> Date {
      now.addingTimeInterval(-Double(daysAgo) * 86_400)
    }

    try upsertHistoricalExpense(
      HistoricalExpenseSpec(
        id: fixtures.memberOneTxnId,
        payee: fixtures.memberOneTxnPayee,
        date: date(daysAgo: fixtures.memberOneTxnDaysAgo),
        amount: amount,
        accountId: fixtures.memberOneId,
        categoryId: nil),
      in: database)
    try upsertHistoricalExpense(
      HistoricalExpenseSpec(
        id: fixtures.memberTwoTxnId,
        payee: fixtures.memberTwoTxnPayee,
        date: date(daysAgo: fixtures.memberTwoTxnDaysAgo),
        amount: amount,
        accountId: fixtures.memberTwoId,
        categoryId: nil),
      in: database)
    try upsertHistoricalExpense(
      HistoricalExpenseSpec(
        id: fixtures.outsiderTxnId,
        payee: fixtures.outsiderTxnPayee,
        date: date(daysAgo: fixtures.outsiderTxnDaysAgo),
        amount: amount,
        accountId: fixtures.outsiderId,
        categoryId: nil),
      in: database)
  }
}
