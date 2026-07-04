import Foundation

/// Parses a UUID literal used in a deterministic test seed. Crashes with
/// a clear message if the literal is malformed; never substitutes a
/// random UUID (which would make failure artefacts non-diffable).
/// File-private mirror of the helper in `UITestSeed.swift` — kept local
/// so the fixtures file has no cross-file dependency for parsing its
/// own literals.
private func uuidLiteral(_ string: String) -> UUID {
  guard let uuid = UUID(uuidString: string) else {
    fatalError("Malformed UUID literal in test seed: \(string)")
  }
  return uuid
}

/// Fixed-UUID fixtures used by both the app (when seeding) and UI-test
/// drivers (when resolving identifiers). Grouping constants by seed family
/// keeps fixtures local to the scenario that needs them.
public enum UITestFixtures {
  /// Fixtures for the `.tradeBaseline` seed.
  ///
  /// Entities (all fixed, deterministic):
  ///   - Profile `personal` — label "Personal", currency AUD, CloudKit-backed.
  ///   - Account `checking` — "Checking", bank, AUD.
  ///   - Account `brokerage` — "Brokerage", investment, AUD,
  ///     `valuationMode = .recordedValue` (legacy). One
  ///     `InvestmentValue` snapshot for $12,345.00 on 2026-04-15 UTC, so
  ///     `EditAccountValuationPickerTests` can assert the picker is
  ///     shown for the legacy-with-data scenario.
  ///   - Account `tradesBrokerage` — "Trades brokerage", investment,
  ///     AUD, `valuationMode = .calculatedFromTrades` and **no**
  ///     `InvestmentValue` snapshots. Drives the
  ///     "calculatedFromTrades + no snapshots → picker hidden" half of
  ///     the same test pair.
  ///   - Account `usd` — "USD Savings", bank, USD.
  ///   - Transaction `bhpPurchase` — trade on 2026-04-01 UTC, payee
  ///     "BHP Purchase". Two legs in the profile instrument: −5,000.00 AUD
  ///     from `checking` (expense) and +5,000.00 AUD into `brokerage`
  ///     (income). A simplified stand-in until cross-instrument trades land.
  ///   - `historicalPayees` — four single-leg expenses from `checking` that
  ///     give `fetchPayeeSuggestions` something to match against. "Woolworths"
  ///     occurs twice so it sorts strictly above single-occurrence payees
  ///     regardless of dictionary iteration order.
  ///   - Earmark `renameTargetEarmark` — "Holiday", no balance/target. Gives
  ///     sidebar-rename UI tests an earmark row to drive.
  ///   - Account group `renameTargetGroup` — "Investments Group", investments
  ///     bucket, no members. Gives sidebar-rename UI tests a group row to
  ///     drive.
  public enum TradeBaseline {
    public static let profileId = uuidLiteral("A1000000-0000-0000-0000-000000000001")
    public static let profileLabel = "Personal"
    public static let profileCurrencyCode = "AUD"

    public static let checkingAccountId = uuidLiteral("A1000000-0000-0000-0000-000000000010")
    public static let checkingAccountName = "Checking"

    public static let brokerageAccountId = uuidLiteral("A1000000-0000-0000-0000-000000000011")
    public static let brokerageAccountName = "Brokerage"

    /// A USD-denominated account so the cross-currency test can switch a
    /// transfer's counterpart leg to a different instrument.
    public static let usdAccountId = uuidLiteral("A1000000-0000-0000-0000-000000000012")
    public static let usdAccountName = "USD Savings"
    public static let usdAccountInstrumentCode = "USD"

    /// Investment account in `.calculatedFromTrades` mode with no
    /// `InvestmentValue` snapshots. Drives the
    /// "calculatedFromTrades + no snapshots → picker hidden" test in
    /// `EditAccountValuationPickerTests`.
    public static let tradesBrokerageAccountId =
      uuidLiteral("A1000000-0000-0000-0000-000000000013")
    public static let tradesBrokerageAccountName = "Trades brokerage"

    // Earmark for sidebar-rename UI coverage. Lives in the same profile;
    // no balance / target. Drive via UITestIdentifiers.Sidebar.earmark(id).
    public static let renameTargetEarmarkId =
      uuidLiteral("A1000000-0000-0000-0000-0000000000E1")
    public static let renameTargetEarmarkName = "Holiday"

    // Account group for sidebar-rename UI coverage. Bucket: investments
    // so it nests under the same source-list section as the existing
    // brokerage / tradesBrokerage accounts. Has no members — group
    // membership is out of scope for #999 and the rename test only
    // needs the row to be present and renameable.
    public static let renameTargetGroupId =
      uuidLiteral("A1000000-0000-0000-0000-0000000000F1")
    public static let renameTargetGroupName = "Investments Group"

    /// One `InvestmentValue` snapshot for the existing `brokerage`
    /// (recordedValue mode) account. Drives the "recordedValue + has
    /// snapshot → picker shown" test in
    /// `EditAccountValuationPickerTests`.
    public static let brokerageSnapshotId =
      uuidLiteral("A1000000-0000-0000-0000-000000000060")
    public static let brokerageSnapshotCents = 1_234_500  // 12,345.00 AUD
    /// 2026-04-15 00:00:00 UTC.
    public static let brokerageSnapshotDate =
      Date(timeIntervalSince1970: 1_776_211_200)

    public static let bhpPurchaseId = uuidLiteral("A1000000-0000-0000-0000-000000000020")
    public static let bhpPurchasePayee = "BHP Purchase"
    public static let bhpPurchaseAmountCents = 500_000  // 5,000.00 AUD
    /// 2026-04-01 00:00:00 UTC.
    public static let bhpPurchaseDate = Date(timeIntervalSince1970: 1_775_001_600)

    /// Cents moved by every historical expense. Kept identical across the
    /// list so tests that care only about payee text don't encode amounts.
    public static let historicalExpenseAmountCents = 5_000  // 50.00 AUD

    // MARK: - Categories
    //
    // A minimal category set that gives the autocomplete dropdown
    // matches for the prefixes exercised by the multi-leg isolation test:
    //
    //   "G" → [Groceries, Gym]           (count = 2)
    //   "Gr" → [Groceries]                (count = 1)
    //
    // Seeded flat — no parent hierarchy — because the test only asserts
    // dropdown visibility, not label formatting.
    public static let groceriesCategoryId =
      uuidLiteral("A1000000-0000-0000-0000-000000000040")
    public static let groceriesCategoryName = "Groceries"
    public static let gymCategoryId =
      uuidLiteral("A1000000-0000-0000-0000-000000000041")
    public static let gymCategoryName = "Gym"

    // MARK: - Custom (multi-leg) transaction
    //
    // A two-leg expense split from `checking`, both legs with the same
    // account so `Transaction.isSimple == false` → `TransactionDraft.isCustom
    // == true` → the detail view renders per-leg sections with category
    // autocomplete fields.
    public static let splitShopId = uuidLiteral("A1000000-0000-0000-0000-000000000050")
    public static let splitShopPayee = "Split Shop"
    /// 2026-03-23 00:00:00 UTC — between the historical expenses and the
    /// BHP trade.
    public static let splitShopDate = Date(timeIntervalSince1970: 1_774_224_000)
    public static let splitShopLegAAmountCents = 3_000  // 30.00 AUD
    public static let splitShopLegBAmountCents = 2_000  // 20.00 AUD

    /// Four historical expense transactions from `checking`, ordered by
    /// date. Payee frequency is the only axis `fetchPayeeSuggestions` sorts
    /// on; "Woolworths" appears twice so it ranks strictly above
    /// "Woolworths Metro" for the prefix "Wool".
    ///
    /// The most recent "Woolworths" (2026-03-20) carries `groceriesCategoryId`
    /// so the autofill flow has a category to copy when a user selects the
    /// "Woolworths" suggestion. The earlier entries leave the category nil so
    /// the seed still exercises the common "no prior category" path.
    public static let historicalPayees: [UITestHistoricalExpense] = [
      UITestHistoricalExpense(
        id: uuidLiteral("A1000000-0000-0000-0000-000000000030"),
        payee: "Coles",
        date: Date(timeIntervalSince1970: 1_772_668_800)  // 2026-03-05 UTC
      ),
      UITestHistoricalExpense(
        id: uuidLiteral("A1000000-0000-0000-0000-000000000031"),
        payee: "Woolworths",
        date: Date(timeIntervalSince1970: 1_773_100_800)  // 2026-03-10 UTC
      ),
      UITestHistoricalExpense(
        id: uuidLiteral("A1000000-0000-0000-0000-000000000032"),
        payee: "Woolworths Metro",
        date: Date(timeIntervalSince1970: 1_773_532_800)  // 2026-03-15 UTC
      ),
      UITestHistoricalExpense(
        id: uuidLiteral("A1000000-0000-0000-0000-000000000033"),
        payee: "Woolworths",
        date: Date(timeIntervalSince1970: 1_773_964_800),  // 2026-03-20 UTC
        categoryId: groceriesCategoryId
      ),
    ]
  }

  /// Fixtures for the `.cryptoCatalogPreloaded` seed.
  ///
  /// Entities (all fixed, deterministic):
  ///   - Profile `personal` — same UUID/label/currency as `TradeBaseline`,
  ///     CloudKit-backed (a CryptoTokenStore is only built for CloudKit
  ///     profiles; the Crypto Settings tab is otherwise hidden).
  ///   - Catalog: a single coin "Uniswap" (UNI) with one platform binding
  ///     `(slug=ethereum, chainId=1, contractAddress=0x1F98…F984)`. The
  ///     contract address is lower-cased by `Instrument.crypto(...)` so the
  ///     resulting Instrument id is
  ///     `1:0x1f9840a85d5af5bf1d1762f925bdaddc4201f984`.
  ///   - Resolution result: the deterministic
  ///     `(coingeckoId="uniswap", cryptocompareSymbol="UNI",
  ///     binanceSymbol="UNIUSDT")` triple returned by the stubbed
  ///     `TokenResolutionClient` for the matching `(chainId, contract)`.
  public enum CryptoCatalogPreloaded {
    public static let profileId = UITestFixtures.TradeBaseline.profileId
    public static let profileLabel = UITestFixtures.TradeBaseline.profileLabel
    public static let profileCurrencyCode = UITestFixtures.TradeBaseline.profileCurrencyCode

    /// The single coin in the catalog snapshot.
    public static let coingeckoId = "uniswap"
    public static let symbol = "UNI"
    public static let name = "Uniswap"
    public static let chainSlug = "ethereum"
    public static let chainId = 1
    /// Mixed-case as in the design spec; lower-cased by `Instrument.crypto`
    /// when the Instrument id is built.
    public static let contractAddress = "0x1F9840a85d5aF5bf1D1762F925BDADdC4201F984"

    /// The Instrument id the registered token will carry — built from the
    /// chainId + lower-cased contract address.
    public static let instrumentId = "1:0x1f9840a85d5af5bf1d1762f925bdaddc4201f984"

    /// Provider IDs the stubbed `TokenResolutionClient` returns for the
    /// matching `(chainId, contract)` pair.
    public static let coingeckoMappingId = "uniswap"
    public static let cryptocompareSymbol = "UNI"
    public static let binanceSymbol = "UNIUSDT"
  }

  /// Fixtures for the `.tradeReady` seed.
  ///
  /// Entities (all fixed, deterministic):
  ///   - Profile `personal` — label "Personal", currency AUD, CloudKit-backed.
  ///   - Account `brokerage` — "Brokerage", bank, AUD.
  ///   - Instrument `vgsax` — VGS.AX stock on ASX, registered so it appears
  ///     in `InstrumentPickerField`.
  ///   - Category `brokerage` — "Brokerage", so the fee leg can select it.
  public enum TradeReady {
    public static let profileId = uuidLiteral("A3000000-0000-0000-0000-000000000001")
    public static let profileLabel = "Personal"
    public static let profileCurrencyCode = "AUD"

    public static let brokerageAccountId = uuidLiteral("A3000000-0000-0000-0000-000000000010")
    public static let brokerageAccountName = "Brokerage"

    public static let vgsaxInstrumentId = "ASX:VGS.AX"
    public static let vgsaxTicker = "VGS.AX"
    public static let vgsaxExchange = "ASX"
    public static let vgsaxName = "VGS"

    public static let brokerageCategoryId = uuidLiteral("A3000000-0000-0000-0000-000000000040")
    public static let brokerageCategoryName = "Brokerage"

    // MARK: - Trade transactions

    /// 14-Apr-26 buy: −$300 AUD → +20 VGS.AX, $10 brokerage fee.
    public static let trade1Id = uuidLiteral("A3000000-0000-0000-0000-000000000020")
    /// 21-Apr-26 buy: −$160 AUD → +10 VGS.AX, no fee.
    public static let trade2Id = uuidLiteral("A3000000-0000-0000-0000-000000000021")
    /// 28-Apr-26 sell: +$425 AUD → −10 VGS.AX, $5 brokerage fee.
    public static let trade3Id = uuidLiteral("A3000000-0000-0000-0000-000000000022")
  }

  /// Fixtures for the `.transferDetectionBaseline` seed.
  ///
  /// Entities (all fixed, deterministic):
  ///   - Profile `personal` — label "Personal", currency AUD,
  ///     CloudKit-backed (the transfer-detection coordinator is owned by
  ///     `ImportStore`, which is only built for CloudKit profiles).
  ///   - Account `everyday` — "Everyday", bank, AUD.
  ///   - Account `savings` — "Savings", bank, AUD.
  ///   - Merge pair:
  ///     - `mergeOutgoingId` — Everyday, −500c, 2026-04-01, `.expense`.
  ///     - `mergeIncomingId` — Savings, +500c, 2026-04-02, `.income`.
  ///       One day apart, well inside the auto-detection window.
  ///   - Dismiss pair:
  ///     - `dismissOutgoingId` — Everyday, −800c, 2026-04-05, `.expense`.
  ///     - `dismissIncomingId` — Savings, +800c, 2026-04-06, `.income`.
  ///
  /// All four transactions share the profile instrument and carry a
  /// `.single` import origin so they appear in Recently Added. Both
  /// members of each pair carry a `TransferSuggestion` pointing at the
  /// other (counterpart id + `suggestedAt`), so the passive "possible
  /// transfer" pill renders for all four rows at first launch with no
  /// detection-timing dependency.
  public enum TransferDetection {
    public static let profileId = uuidLiteral("C1000000-0000-0000-0000-000000000001")
    public static let profileLabel = "Personal"
    public static let profileCurrencyCode = "AUD"

    public static let everydayAccountId = uuidLiteral("C1000000-0000-0000-0000-0000000000A1")
    public static let everydayAccountName = "Everyday"
    public static let savingsAccountId = uuidLiteral("C1000000-0000-0000-0000-0000000000A2")
    public static let savingsAccountName = "Savings"

    /// Merge pair — collapsed by the merge test. −500c Everyday paired
    /// with +500c Savings, one day apart.
    public static let mergeOutgoingId = uuidLiteral("C1000000-0000-0000-0000-0000000000B1")
    public static let mergeOutgoingCents = 500  // 5.00 AUD outflow
    /// 2026-04-01 00:00:00 UTC.
    public static let mergeOutgoingDate = Date(timeIntervalSince1970: 1_775_001_600)
    public static let mergeOutgoingPayee = "Transfer to Savings"

    public static let mergeIncomingId = uuidLiteral("C1000000-0000-0000-0000-0000000000B2")
    public static let mergeIncomingCents = 500  // 5.00 AUD inflow
    /// 2026-04-02 00:00:00 UTC.
    public static let mergeIncomingDate = Date(timeIntervalSince1970: 1_775_088_000)
    public static let mergeIncomingPayee = "Transfer from Everyday"

    /// Dismiss pair — marked "not a transfer" by the dismiss test.
    /// −800c Everyday paired with +800c Savings, one day apart.
    public static let dismissOutgoingId = uuidLiteral("C1000000-0000-0000-0000-0000000000B3")
    public static let dismissOutgoingCents = 800  // 8.00 AUD outflow
    /// 2026-04-05 00:00:00 UTC.
    public static let dismissOutgoingDate = Date(timeIntervalSince1970: 1_775_347_200)
    public static let dismissOutgoingPayee = "Transfer to Savings"

    public static let dismissIncomingId = uuidLiteral("C1000000-0000-0000-0000-0000000000B4")
    public static let dismissIncomingCents = 800  // 8.00 AUD inflow
    /// 2026-04-06 00:00:00 UTC.
    public static let dismissIncomingDate = Date(timeIntervalSince1970: 1_775_433_600)
    public static let dismissIncomingPayee = "Transfer from Everyday"

    /// Deterministic `TransferSuggestion.suggestedAt` written onto every
    /// pair member. The exact value is irrelevant to the UI (the pill is
    /// driven by the suggestion's presence) but kept fixed so the
    /// `seed.txt` failure artefact is diffable. 2026-04-10 00:00:00 UTC.
    public static let suggestedAt = Date(timeIntervalSince1970: 1_775_779_200)

    /// Parser identifier stamped on every seeded import origin. A stable
    /// non-empty string is all `RecentlyAddedViewModel` requires.
    public static let parserIdentifier = "ui-test-seed"
    public static let sourceFilename = "transfer-detection-seed.csv"
  }

  /// Fixtures for the `.pendingWebImportOneChaseInbox` seed.
  ///
  /// The seed reuses the `tradeBaseline` profile (so the
  /// `DeepLinkCoordinator` has a live `ImportStore` to forward the
  /// payload into) and additionally writes a deterministic Chase-shaped
  /// `ImportPayload` into the fallback inbox directory pointed at by
  /// `MOOLAH_UI_TEST_INBOX_DIR`. The banner reads that file at first
  /// paint and reports `"1 pending import from chase.com"`.
  public enum PendingWebImportOneChaseInbox {
    public static let payloadId = uuidLiteral("D0D0D000-0000-0000-0000-000000000001")
    public static let sourceHost = "chase.com"
    public static let sourceURL = "https://chase.com/statements/checking"
    public static let accountHint = "Total Checking …4242"
    public static let currencyHint = "USD"
    /// 2026-04-15 00:00:00 UTC — the fixed `capturedAt` so the
    /// `seed.txt` failure artefact is diffable.
    public static let capturedAt = Date(timeIntervalSince1970: 1_776_211_200)
    /// Banner copy the driver asserts on. Mirrors `PendingImportsBanner`'s
    /// `"1 pending import from \(host)"` literal — kept here so the
    /// expectation is co-located with the rest of the seed fixture
    /// metadata that gets surfaced into the `seed.txt` artefact.
    public static let expectedBannerText = "1 pending import from \(sourceHost)"
  }

  /// Fixtures for the `.walletHeaderSyncError` seed.
  ///
  /// Entities (all fixed, deterministic):
  ///   - Profile `personal` — label "Personal", currency AUD,
  ///     CloudKit-backed (a `cryptoSyncStore` is only built for CloudKit
  ///     profiles; `CryptoWalletAccountView.walletHeader` returns
  ///     `EmptyView` otherwise).
  ///   - Account `wallet` — "Ethereum Wallet", crypto, AUD denomination,
  ///     `chainId = 1` (Ethereum mainnet), `walletAddress` set to a
  ///     deterministic 42-char hex address.
  ///   - `wallet_sync_state` row — seeded with a `network` error so
  ///     `SyncedAccountHeaderView.errorCaption` is non-nil at first paint.
  public enum WalletHeaderSyncError {
    public static let profileId = uuidLiteral("E1000000-0000-0000-0000-000000000001")
    public static let profileLabel = "Personal"
    public static let profileCurrencyCode = "AUD"

    public static let walletAccountId = uuidLiteral("E1000000-0000-0000-0000-000000000010")
    public static let walletAccountName = "Ethereum Wallet"
    /// Deterministic 42-char Ethereum address. Not a real wallet.
    public static let walletAddress = "0xe1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1"
    public static let walletChainId = 1
  }
}

/// Environment-variable names the app and UI-test target both read.
///
/// Compiled into both targets so the launch wiring (`MoolahApp.launch`)
/// and the consumers (e.g. the fallback inbox in `MoolahApp+Setup`) cannot
/// disagree on the key.
public enum UITestEnvironment {
  /// Directory the app's `PendingImportsBannerFallback` inbox is rooted
  /// at when `InboxWriter.shared()` is unavailable (the `--ui-testing`
  /// case). Both the seed hydrator (which writes the fixture payload)
  /// and the app's launch wiring (which constructs the `InboxWriter`)
  /// read this value, so the seed's writes and the banner's reads land
  /// on the same on-disk directory.
  public static let inboxDirectory = "MOOLAH_UI_TEST_INBOX_DIR"
}
