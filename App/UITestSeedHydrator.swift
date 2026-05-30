import Foundation
import GRDB

/// Populates an in-memory `ProfileContainerManager` from a named `UITestSeed`.
///
/// Called during `MoolahApp.init` when the process was launched with
/// `--ui-testing`. Deterministic by contract: every invocation produces
/// records with the UUIDs and values declared in `UITestFixtures`, so drivers
/// can reference entities symbolically.
///
/// Idempotent: running twice on the same manager does not double-insert,
/// which keeps re-launches during driver iteration robust.
@MainActor
enum UITestSeedHydrator {
  /// Seeds `manager` from the given seed and returns the resulting `Profile`,
  /// or `nil` for seeds that start without an active profile (e.g. Welcome
  /// seeds that exercise the first-run experience before any profile is open).
  ///
  /// - Parameter seed: the named data set to hydrate.
  /// - Parameter manager: an in-memory `ProfileContainerManager` (see
  ///   `ProfileContainerManager.forTesting()`).
  /// - Returns: the seeded profile ready to drive a window, or `nil` when the
  ///   seed starts from a no-profile state and relies on `WelcomeView`.
  @discardableResult
  static func hydrate(
    _ seed: UITestSeed,
    into manager: ProfileContainerManager
  ) throws -> Profile? {
    switch seed {
    case .tradeBaseline,
      .sidebarFooterUpToDate,
      .sidebarFooterReceiving,
      .sidebarFooterSending,
      .cryptoCatalogPreloaded:
      // All these seeds reuse the `tradeBaseline` fixture as their
      // base profile and exercise an orthogonal surface (sidebar
      // footer, crypto picker, etc) layered on top of it. Folding
      // them into a single case keeps the dispatch cyclomatically
      // simple even as new "trade-baseline + X" seeds are added.
      return try hydrateTradeBaseline(into: manager)
    case .welcomeEmpty, .welcomeDownloading:
      // No profile is created: the launcher opens the window with
      // nil bindings so `ProfileWindowView` routes to `WelcomeView`.
      // For `welcomeDownloading`, `applySeedProgressFixtures` drives
      // `SyncProgress` separately.
      return nil
    case .welcomeSingleCloudProfile, .welcomeMultipleCloudProfiles:
      try hydrateWelcomeProfiles(for: seed, into: manager)
      // Return nil so `uiTestingProfileId` stays unset and the normal
      // auto-activation flow in `ProfileStore.loadCloudProfiles` can fire.
      return nil
    case .tradeReady:
      return try hydrateTradeReady(into: manager)
    case .incompatibleProfile:
      try hydrateIncompatibleProfile(into: manager)
      // Return nil → no auto-activate, picker renders, test taps the row.
      return nil
    case .transferDetectionBaseline:
      return try hydrateTransferDetectionBaseline(into: manager)
    case .pendingWebImportOneChaseInbox:
      let profile = try hydrateTradeBaseline(into: manager)
      try seedPendingWebImportInbox()
      return profile
    }
  }

  /// Dispatches the welcome-profile-picker seeds. Hydrates one or two
  /// `Profile` records into the index depending on the seed; either way
  /// the caller returns `nil` so the auto-activation flow fires
  /// (single) or the picker renders (multiple). Factored out so the
  /// top-level `hydrate(_:into:)` switch stays under SwiftLint's
  /// cyclomatic-complexity threshold as new seeds are added.
  private static func hydrateWelcomeProfiles(
    for seed: UITestSeed, into manager: ProfileContainerManager
  ) throws {
    try hydrateWelcomeProfile(
      id: UITestWelcomeFixtures.householdProfileId,
      label: UITestWelcomeFixtures.householdProfileLabel,
      into: manager
    )
    if seed == .welcomeMultipleCloudProfiles {
      try hydrateWelcomeProfile(
        id: UITestWelcomeFixtures.sideBusinessProfileId,
        label: UITestWelcomeFixtures.sideBusinessProfileLabel,
        into: manager
      )
    }
  }

  // The `.pendingWebImportOneChaseInbox` seed's inbox-fixture write
  // (`seedPendingWebImportInbox`) lives in
  // `UITestSeedHydrator+PendingWebImport.swift` to keep this enum body
  // under SwiftLint's `type_body_length` threshold as new seeds are
  // added — mirrors the `+TradeReady`, `+TransferDetection`, `+Upserts`
  // split.

  /// Seeds two profiles in the index — one compatible (v0) and one
  /// incompatible (`DataFormatVersion.current + 1`). The second profile
  /// forces the multi-profile picker to render (single-profile seeds
  /// would auto-activate via `WelcomeView`), giving the test a path to
  /// reach `IncompatibleProfileView` by tapping the incompatible row.
  private static func hydrateIncompatibleProfile(
    into manager: ProfileContainerManager
  ) throws {
    let fixtures = UITestIncompatibleProfileFixtures.self
    // Compatible profile first so the picker has at least one valid row.
    try upsertProfile(
      Profile(
        id: fixtures.compatibleProfileId,
        label: fixtures.compatibleProfileLabel,
        currencyCode: fixtures.profileCurrencyCode,
        financialYearStartMonth: 7,
        createdAt: fixtures.createdAt,
        dataFormatVersion: 0),
      into: manager)
    try upsertProfile(
      Profile(
        id: fixtures.profileId,
        label: fixtures.profileLabel,
        currencyCode: fixtures.profileCurrencyCode,
        financialYearStartMonth: 7,
        createdAt: fixtures.createdAt,
        dataFormatVersion: DataFormatVersion.current + 1),
      into: manager)
  }

  private static func hydrateWelcomeProfile(
    id: UUID,
    label: String,
    into manager: ProfileContainerManager
  ) throws {
    let profile = Profile(
      id: id,
      label: label,
      currencyCode: UITestWelcomeFixtures.profileCurrencyCode,
      financialYearStartMonth: 7,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    try upsertProfile(profile, into: manager)
  }

  // MARK: - Seeds

  private static func hydrateTradeBaseline(
    into manager: ProfileContainerManager
  ) throws -> Profile {
    let fixtures = UITestFixtures.TradeBaseline.self

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
    // the per-profile `instrument` table was removed by
    // `v10_drop_shared_instrument_legacy`. Register every denomination
    // the baseline references there before the per-profile rows fan a
    // domain `Instrument` out of a leg. (Fiat is ambient via the ISO
    // fallback, but registering keeps the seed explicit and matches the
    // non-fiat path.)
    try manager.profileIndexDatabase.write { database in
      try upsertInstrument(instrument, in: database)
      try upsertInstrument(.USD, in: database)
    }

    try database.write { database in
      try seedTradeBaselineAccounts(instrument: instrument, in: database)
      // Snapshots depend on accounts existing; transactions don't depend on
      // either. Order accounts → snapshots → transactions so the
      // dependency chain reads top-to-bottom.
      try seedTradeBaselineInvestmentValues(instrument: instrument, in: database)
      try seedTradeBaselineTransactions(instrument: instrument, in: database)
      try seedTradeBaselineRenameTargets(instrument: instrument, in: database)
    }
    return profile
  }

  /// Seed the accounts used by the Trade Baseline fixture: AUD checking +
  /// investment + a USD account so the cross-currency test can switch a
  /// transfer leg's counterpart instrument.
  private static func seedTradeBaselineAccounts(
    instrument: Instrument, in database: Database
  ) throws {
    // Instruments are registered on the shared profile-index DB by the
    // caller (`hydrateTradeBaseline`); the per-profile DB has no
    // `instrument` table.
    let fixtures = UITestFixtures.TradeBaseline.self
    try upsertAccount(
      AccountSpec(
        id: fixtures.checkingAccountId,
        name: fixtures.checkingAccountName,
        type: .bank,
        instrumentId: instrument.id,
        position: 0),
      in: database)
    try upsertAccount(
      AccountSpec(
        id: fixtures.brokerageAccountId,
        name: fixtures.brokerageAccountName,
        type: .investment,
        instrumentId: instrument.id,
        position: 1),
      in: database)

    let usd = Instrument.USD
    try upsertAccount(
      AccountSpec(
        id: fixtures.usdAccountId,
        name: fixtures.usdAccountName,
        type: .bank,
        instrumentId: usd.id,
        position: 2),
      in: database)

    // A second investment account in `.calculatedFromTrades` mode with
    // no `InvestmentValue` snapshots, so `EditAccountValuationPickerTests`
    // can verify the picker stays hidden for new trade-driven accounts.
    try upsertAccount(
      AccountSpec(
        id: fixtures.tradesBrokerageAccountId,
        name: fixtures.tradesBrokerageAccountName,
        type: .investment,
        instrumentId: instrument.id,
        position: 3,
        valuationMode: .calculatedFromTrades),
      in: database)
  }

  /// Seed one `InvestmentValue` snapshot on the existing
  /// `.recordedValue`-mode brokerage account, so
  /// `EditAccountValuationPickerTests` can verify the picker is shown
  /// for the legacy-with-data scenario.
  private static func seedTradeBaselineInvestmentValues(
    instrument: Instrument, in database: Database
  ) throws {
    let fixtures = UITestFixtures.TradeBaseline.self
    try upsertInvestmentValue(
      UITestInvestmentValueSeed(
        id: fixtures.brokerageSnapshotId,
        accountId: fixtures.brokerageAccountId,
        date: fixtures.brokerageSnapshotDate,
        instrumentId: instrument.id,
        cents: fixtures.brokerageSnapshotCents),
      in: database)
  }

  /// Seed the transactions used by the Trade Baseline fixture.
  private static func seedTradeBaselineTransactions(
    instrument: Instrument, in database: Database
  ) throws {
    let fixtures = UITestFixtures.TradeBaseline.self
    try upsertTrade(
      TradeSpec(
        id: fixtures.bhpPurchaseId,
        payee: fixtures.bhpPurchasePayee,
        date: fixtures.bhpPurchaseDate,
        amount: InstrumentAmount(
          quantity: Decimal(fixtures.bhpPurchaseAmountCents) / 100,
          instrument: instrument),
        fromAccountId: fixtures.checkingAccountId,
        toAccountId: fixtures.brokerageAccountId),
      in: database)

    // Categories must exist before any leg references them by id (the
    // `transaction_leg.category_id` FK is enforced by the GRDB schema), so
    // upsert them ahead of the historical expense loop (one of those
    // entries attaches `groceriesCategoryId`).
    try upsertCategory(
      id: fixtures.groceriesCategoryId, name: fixtures.groceriesCategoryName, in: database)
    try upsertCategory(
      id: fixtures.gymCategoryId, name: fixtures.gymCategoryName, in: database)

    let historicalAmount = InstrumentAmount(
      quantity: Decimal(fixtures.historicalExpenseAmountCents) / 100,
      instrument: instrument)
    for historical in fixtures.historicalPayees {
      try upsertHistoricalExpense(
        HistoricalExpenseSpec(
          id: historical.id,
          payee: historical.payee,
          date: historical.date,
          amount: historicalAmount,
          accountId: fixtures.checkingAccountId,
          categoryId: historical.categoryId),
        in: database)
    }

    try upsertCustomExpenseSplit(
      CustomExpenseSplitSpec(
        id: fixtures.splitShopId,
        payee: fixtures.splitShopPayee,
        date: fixtures.splitShopDate,
        legAAmount: InstrumentAmount(
          quantity: Decimal(fixtures.splitShopLegAAmountCents) / 100,
          instrument: instrument),
        legBAmount: InstrumentAmount(
          quantity: Decimal(fixtures.splitShopLegBAmountCents) / 100,
          instrument: instrument),
        accountId: fixtures.checkingAccountId),
      in: database)
  }

  /// Seeds one earmark + one investments-bucket account group used by
  /// the macOS sidebar-rename UI tests. Both are nominal fixtures with
  /// no balance / membership; the tests only need the rows present and
  /// renameable.
  private static func seedTradeBaselineRenameTargets(
    instrument: Instrument, in database: Database
  ) throws {
    let fixtures = UITestFixtures.TradeBaseline.self
    try upsertEarmark(
      EarmarkSpec(
        id: fixtures.renameTargetEarmarkId,
        name: fixtures.renameTargetEarmarkName,
        instrumentId: instrument.id),
      in: database)
    try upsertAccountGroup(
      AccountGroupSpec(
        id: fixtures.renameTargetGroupId,
        name: fixtures.renameTargetGroupName,
        bucketRawValue: AccountBucket.investments.rawValue,
        instrumentId: instrument.id,
        position: 0),
      in: database)
  }

}
