import Foundation

/// Parses a UUID literal used in a deterministic test seed. Crashes with a
/// clear message if the literal is malformed; never substitutes a random
/// UUID (which would make failure artefacts non-diffable). Preferred over
/// force-unwrap so each literal does not add a SwiftLint baseline entry.
private func uuidLiteral(_ string: String) -> UUID {
  guard let uuid = UUID(uuidString: string) else {
    fatalError("Malformed UUID literal in test seed: \(string)")
  }
  return uuid
}

/// Named deterministic data sets that the app hydrates from when launched
/// with the `--ui-testing` argument and `UI_TESTING_SEED` set to the seed's
/// raw value.
///
/// Compiled into both the main app and `MoolahUITests_macOS` so:
///   - tests select a seed symbolically via `MoolahApp.launch(seed: .tradeBaseline)`,
///   - the app reads `UI_TESTING_SEED` and hydrates from the matching case,
///   - drivers reference fixtures (e.g. `UITestFixtures.TradeBaseline.checkingAccountId`)
///     by the same UUID the app wrote.
///
/// Every seed is deterministic: all UUIDs are hard-coded literals and every
/// entity's name, amount, and date is a constant. The `seed.txt` failure
/// artefact is generated from this metadata.
public enum UITestSeed: String, CaseIterable, Sendable {
  /// A CloudKit-backed profile with a checking account, a brokerage
  /// investment account, one trade transaction with two legs, and a
  /// handful of historical expenses with repeated payees. The baseline
  /// for `TransactionDetailView` tests covering focus, payee
  /// autocomplete, and cross-currency.
  case tradeBaseline

  /// Blank index container — no profiles. Drives the first-run
  /// `WelcomeView` `.heroChecking` / `.heroNoneFound` branches.
  case welcomeEmpty

  /// One `ProfileRecord` seeded in the index. Triggers auto-activation
  /// into `SessionRootView` via `WelcomeView`'s `.autoActivateSingle`
  /// branch.
  case welcomeSingleCloudProfile

  /// Two `ProfileRecord`s seeded in the index. Drives the multi-profile
  /// picker (`WelcomeView` state 5).
  case welcomeMultipleCloudProfiles

  /// Forces the Welcome screen into `.heroDownloading(received: 1234)` so
  /// the "Found data on iCloud · 1,234 records downloaded" copy and
  /// the de-emphasized "Create a new profile" button can be verified.
  case welcomeDownloading

  /// Drives `SyncProgress` into `.upToDate` with a `lastSettledAt` ~5
  /// minutes in the past so the macOS sidebar footer renders
  /// "Up to date · Updated 5 minutes ago".
  case sidebarFooterUpToDate

  /// Drives `SyncProgress` into `.receiving` with a non-zero count so the
  /// sidebar footer renders the receive label and count.
  case sidebarFooterReceiving

  /// Drives `SyncProgress` into `.sending` with `pendingUploads = 12`.
  case sidebarFooterSending

  /// CloudKit-backed profile (same shape as `tradeBaseline`) plus a
  /// deterministic crypto-token catalogue and resolution stub installed
  /// in place of the live `SQLiteCoinGeckoCatalog` /
  /// `CompositeTokenResolutionClient`. The catalogue contains exactly one
  /// row (Uniswap, ethereum chainId 1) and the stub resolver returns the
  /// matching `(coingeckoId, binanceSymbol)` pair.
  /// Drives the Settings → Crypto → Add Token end-to-end test without
  /// touching the network. See `UITestFixtures.CryptoCatalogPreloaded` for
  /// the complete fixture (instrumentId, chainId, contractAddress, provider
  /// IDs) so the `seed.txt` artefact reader can resolve every reference
  /// without cross-file lookup.
  ///
  /// Also reused (via `needsStubbedRPCProbe`) as the seed for the Custom
  /// RPC Endpoints Settings section test, since it's already a network-free
  /// Settings → Crypto tab seed.
  case cryptoCatalogPreloaded

  /// A CloudKit-backed AUD profile with one bank account named "Brokerage",
  /// a registered VGS.AX stock instrument, and a "Brokerage" category.
  /// Drives the `TradeFlowUITests` end-to-end test: switching a transaction
  /// to trade mode, setting paid/received legs and a fee — without any
  /// remote data dependency.
  case tradeReady = "trade-ready"

  /// One profile in the index whose `dataFormatVersion` is one above
  /// the build's `DataFormatVersion.current` — drives
  /// `IncompatibleProfileView` once the picker row is tapped.
  ///
  /// The seed deliberately hydrates a SECOND, compatible profile too:
  /// otherwise `WelcomeView`'s single-profile auto-activate path fires
  /// and the test never sees the picker. With two rows the picker is
  /// always shown, the test taps the incompatible one, and lands on
  /// the incompatible view.
  ///
  /// Fixtures (deterministic UUIDs / labels / dates):
  /// - incompatible: `profileId`, label="Future", dataFormatVersion=current+1
  /// - compatible: `compatibleProfileId`, label="Today", dataFormatVersion=0
  case incompatibleProfile

  /// A CloudKit-backed AUD profile (same shape as `tradeBaseline`) PLUS
  /// a fixture `ImportPayload` JSON pre-written into the fallback inbox
  /// directory pointed at by `MOOLAH_UI_TEST_INBOX_DIR`. Drives the
  /// inbox → review handoff XCUITest: the pending-imports banner reads
  /// the seeded file at first paint and reports `"1 pending import from
  /// chase.com"`; tapping Review forwards the payload through the
  /// existing `DeepLinkCoordinator` → `ImportStore.startWebReview` seam.
  ///
  /// See `UITestFixtures.PendingWebImportOneChaseInbox` for the
  /// deterministic payload contents (UUID, host, rows).
  case pendingWebImportOneChaseInbox = "pending-web-import-one-chase-inbox"

  /// A CloudKit-backed AUD profile with two bank accounts ("Everyday",
  /// "Savings") and four imported single-account transactions forming
  /// two transfer pairs:
  ///   - Merge pair: −500c Everyday / +500c Savings, one day apart.
  ///   - Dismiss pair: −800c Everyday / +800c Savings, one day apart.
  ///
  /// The hydrator writes a `TransferSuggestion` directly onto both
  /// transactions of each pair (each side points at its counterpart),
  /// so the Recently Added pill is deterministic at first launch with
  /// no detection-timing dependency. Each transaction also carries a
  /// `.single` import origin whose `importedAt` is set relative to
  /// hydration time so the rows fall inside the default
  /// `RecentlyAddedView` 24-hour window regardless of when the suite
  /// runs. The "not re-suggested after relaunch" guarantees are
  /// structural: a merged transaction is `.merged` (filtered from
  /// Recently Added and structurally ineligible) and dismiss deletes
  /// the `TransferSuggestion` record so no pair record survives to
  /// re-surface — no startup re-detection runs in the seeded app, so
  /// a relaunch simply re-reads persisted state. See
  /// `UITestFixtures.TransferDetection` for the full fixture table.
  case transferDetectionBaseline

  /// Reuses the `tradeBaseline` profile (so the app boots into the sidebar +
  /// Analysis view with a real "Checking" account) and installs three fixture
  /// `ScoredInsight`s via `UITestSeedInsightOverrides`, bypassing the
  /// statistical detectors. Drives `ForYouPanelUITests`: the For You card
  /// renders the fixtures, dismiss removes one, and the navigable row deep-links
  /// to the checking account. See `UITestFixtures.InsightsForYou`.
  case insightsForYouBaseline = "insights-for-you-baseline"

  /// An AUD profile with an account group ("Filter Group") holding two
  /// bank accounts ("Member One", "Member Two") plus a standalone
  /// non-member account ("Outsider"), each carrying one dated expense.
  /// Drives `GroupTransactionFilterScopeMacTests`: applying a filter while
  /// viewing the group must keep the transaction list scoped to the two
  /// members and never surface the outsider's transaction. See
  /// `UITestFixtures.GroupFilterScope` for the full fixture table.
  case groupFilterScope = "group-filter-scope"

  /// A CloudKit-backed AUD profile with one Ethereum crypto wallet account
  /// whose `wallet_sync_state` row carries a seeded `network` sync error.
  /// Drives `SyncedAccountHeaderTests`: opening the account's detail view
  /// must surface `UITestIdentifiers.WalletAccountHeader.errorCaption` in
  /// the header row, proving the caption element exists and is identified
  /// through the inline-layout change. See
  /// `UITestFixtures.WalletHeaderSyncError` for the full fixture table.
  case walletHeaderSyncError = "wallet-header-sync-error"

  /// A CloudKit-backed AUD profile with two bank accounts:
  ///   - "Multi-Currency" — AUD host + a USD position (non-host holding)
  ///     → macOS layout pins the Positions pane above `[Transactions | Chart]`.
  ///   - "Everyday" — AUD-only positions (host-only) → macOS layout renders
  ///     a single toggle pane with no Positions surface.
  /// Each account carries 2–3 deterministic transactions so the transaction
  /// list and balance chart both have data. Drives `AccountDetailSplitTests`.
  /// See `UITestFixtures.AccountDetailLayout` for the full fixture table.
  case accountDetailLayout = "account-detail-layout"

  /// A CloudKit-backed AUD profile with one `.investment` account in
  /// `.calculatedFromTrades` mode. Two buy trade transactions produce a
  /// net 30 VGS.AX position (non-host holding), which exercises the
  /// Increment-4 `AccountDetailView(alwaysShowsFullSurface: true)` routing
  /// and the macOS pinned-positions layout. Drives
  /// `AccountDetailUnifiedLayoutTests`. See
  /// `UITestFixtures.InvestmentTradeReady` for the full fixture table.
  case investmentTradeReady = "investment-trade-ready"
}

extension UITestSeed {
  /// `true` when the app should treat an Alchemy API key as present
  /// (`CryptoTokenStore.hasAlchemyApiKey == true`) for this seed.
  ///
  /// The harness sets `UITestEnvironment.alchemyKeyPresent` in
  /// `launchEnvironment` rather than writing to the system keychain.
  /// Keychain writes use `SecItemAdd`, which can trigger an interactive
  /// authorization dialog in headless CI environments and cause the
  /// app to hang — passing the signal via an env var avoids that entirely.
  public var needsAlchemyKeyPresent: Bool {
    switch self {
    case .walletHeaderSyncError:
      return true
    case .cryptoCatalogPreloaded, .tradeBaseline, .welcomeEmpty,
      .welcomeSingleCloudProfile, .welcomeMultipleCloudProfiles,
      .welcomeDownloading, .sidebarFooterUpToDate, .sidebarFooterReceiving,
      .sidebarFooterSending, .tradeReady, .incompatibleProfile,
      .transferDetectionBaseline, .pendingWebImportOneChaseInbox,
      .insightsForYouBaseline, .groupFilterScope, .accountDetailLayout,
      .investmentTradeReady:
      return false
    }
  }

  /// `true` when `CryptoTokenStore.probeEndpoints()` should treat every
  /// configured custom RPC endpoint as reachable on chain 1 (Ethereum)
  /// rather than issuing a live `eth_chainId` call — see
  /// `UITestEnvironment.rpcProbeStubbedReachable`. Reuses
  /// `.cryptoCatalogPreloaded` (already a network-free Settings → Crypto
  /// tab seed) for the Custom RPC Endpoints section test rather than
  /// adding a dedicated seed.
  public var needsStubbedRPCProbe: Bool {
    switch self {
    case .cryptoCatalogPreloaded:
      return true
    case .tradeBaseline, .welcomeEmpty, .welcomeSingleCloudProfile,
      .welcomeMultipleCloudProfiles, .welcomeDownloading, .sidebarFooterUpToDate,
      .sidebarFooterReceiving, .sidebarFooterSending, .tradeReady, .incompatibleProfile,
      .transferDetectionBaseline, .pendingWebImportOneChaseInbox,
      .insightsForYouBaseline, .groupFilterScope, .walletHeaderSyncError,
      .accountDetailLayout, .investmentTradeReady:
      return false
    }
  }
}

/// Fixtures for the first-run Welcome seeds. Defined here so both the
/// app (hydration) and UI-test drivers reference the same UUIDs.
public enum UITestWelcomeFixtures {
  public static let householdProfileId = uuidLiteral("B0000000-0000-0000-0000-000000000001")
  public static let householdProfileLabel = "Household"
  public static let sideBusinessProfileId = uuidLiteral("B0000000-0000-0000-0000-000000000002")
  public static let sideBusinessProfileLabel = "Side business"
  public static let profileCurrencyCode = "AUD"
}

/// Fixtures for the `.incompatibleProfile` seed.
///
/// Two profiles are hydrated so the picker is forced to render:
/// `WelcomeView`'s single-profile auto-activate would otherwise skip
/// the picker and the test could never reach
/// `IncompatibleProfileView` via the user-facing flow.
public enum UITestIncompatibleProfileFixtures {
  /// Incompatible profile (dataFormatVersion = DataFormatVersion.current + 1).
  /// Tapping its picker row routes to IncompatibleProfileView.
  public static let profileId = uuidLiteral("D8E1F0AA-0001-4000-8000-0000B0764000")
  public static let profileLabel = "Future"

  /// Compatible profile, exists only to force the multi-profile picker
  /// to render (single-profile seeds auto-activate via WelcomeView).
  public static let compatibleProfileId = uuidLiteral("D8E1F0AA-0001-4000-8000-0000B0764001")
  public static let compatibleProfileLabel = "Today"

  public static let profileCurrencyCode = "AUD"
  public static let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
}

/// A past single-leg expense used to seed payee suggestions.
///
/// `categoryId`, when set, is stored on the leg so the autofill flow
/// (`TransactionDetailView.autofillFromPayee(_:)`) can copy it into a new
/// draft. Most entries leave it `nil`; one entry per scenario carries a
/// category so the test asserts both that autofill fires *and* that it
/// does not open the category picker as a side-effect.
public struct UITestHistoricalExpense: Sendable {
  public let id: UUID
  public let payee: String
  /// How many days before launch the expense is dated. Stored as an offset
  /// (rather than an absolute date) so the transaction always lands inside
  /// rolling report / filter windows — e.g. the Reports view's default
  /// `.last12Months` — no matter what calendar date the suite runs on. The
  /// offset is a deterministic integer, identical in the app and UI-test
  /// processes; only the app resolves it to a wall-clock date, at hydration.
  public let daysAgo: Int
  public let categoryId: UUID?

  public init(id: UUID, payee: String, daysAgo: Int, categoryId: UUID? = nil) {
    self.id = id
    self.payee = payee
    self.daysAgo = daysAgo
    self.categoryId = categoryId
  }

  /// The seeded transaction date, anchored `daysAgo` days before `now`
  /// (launch time). Pass the single `Date()` sampled once per hydration so
  /// every expense in a seed shares one reference instant.
  public func date(now: Date) -> Date {
    now.addingTimeInterval(-Double(daysAgo) * 86_400)
  }
}

/// One `InvestmentValue` snapshot row hydrated alongside an
/// investment account. Stored in the `investment_value` table by
/// `UITestSeedHydrator+Upserts.upsertInvestmentValue`. Used by the
/// `EditAccountView` valuation-picker visibility test:
/// `.recordedValue` accounts that have at least one snapshot show
/// the picker; accounts with no snapshots in `.calculatedFromTrades`
/// hide it.
public struct UITestInvestmentValueSeed: Sendable {
  public let id: UUID
  public let accountId: UUID
  public let date: Date
  public let instrumentId: String
  public let cents: Int

  public init(id: UUID, accountId: UUID, date: Date, instrumentId: String, cents: Int) {
    self.id = id
    self.accountId = accountId
    self.date = date
    self.instrumentId = instrumentId
    self.cents = cents
  }
}
