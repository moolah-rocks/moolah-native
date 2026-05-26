import Foundation

/// String identifiers applied via `.accessibilityIdentifier(_:)` in views and
/// looked up by UI-test drivers via `MoolahApp.element(for:)`.
///
/// Compiled into both the main app and the `MoolahUITests_macOS` target so
/// the two sides reference the same constants — edit in one place.
///
/// Naming format: `area.element[.qualifier]`. Lowercase, dot-separated. New
/// areas extend this enum rather than introducing parallel naming schemes.
///
/// Identifiers are added incrementally as drivers and tests need them — see
/// `guides/UI_TEST_GUIDE.md` §4.
public enum UITestIdentifiers {
  // MARK: - Sidebar

  public enum Sidebar {
    /// Sidebar row for a specific account. `id` is the account's UUID, lowercased.
    ///
    /// The same UUID identifier is applied whether the account renders in
    /// the Current Accounts section or the Investments section — `AccountType`
    /// today is mutually exclusive across the two sections (bank/cc/asset
    /// for Current; investment for Investments). If a future account type
    /// can appear in both sections, switch this to a sectioned namespace
    /// (`sidebar.account.current.<uuid>` vs `sidebar.account.investment.<uuid>`)
    /// to avoid duplicates resolving via `firstMatch`.
    public static func account(_ id: UUID) -> String {
      "sidebar.account.\(id.uuidString.lowercased())"
    }

    /// Sidebar row for a named top-level view (e.g. `"upcoming"`, `"analysis"`).
    public static func view(_ name: String) -> String {
      "sidebar.view.\(name)"
    }

    /// "New Account" toolbar button in the sidebar (macOS only).
    public static let newAccountButton = "sidebar.toolbar.newAccount"

    /// "New Earmark" toolbar button in the sidebar (macOS only). Pinned for
    /// symmetry with `newAccountButton` so a UI test can drive the
    /// create-earmark flow from a zero-earmark seed without further view
    /// changes when one is added.
    public static let newEarmarkButton = "sidebar.toolbar.newEarmark"

    /// "Edit Account…" item in the sidebar account context menu.
    /// Distinct from the menu-bar Account → Edit Account command,
    /// which has the same title but lives in the application menu —
    /// drivers must resolve via this identifier rather than the
    /// shared label.
    public static let editAccountContextMenuItem = "sidebar.contextMenu.editAccount"

    /// "Rename" item in the sidebar context menu — applies to accounts,
    /// earmarks, and (Phase 4 onwards) account groups. Triggers inline
    /// rename mode in the sidebar.
    public static let renameContextMenuItem = "sidebar.contextMenu.rename"
  }

  // MARK: - TransactionList

  public enum TransactionList {
    /// Root container of the transaction list (centre column). Used as a
    /// stable post-condition sentinel after sidebar selection — the row
    /// for any specific transaction is data-dependent, but the container
    /// renders for every account.
    public static let container = "transactionlist.container"

    /// Centre-column row for a specific transaction. `id` is the
    /// transaction's UUID, lowercased.
    public static func transaction(_ id: UUID) -> String {
      "transactionlist.transaction.\(id.uuidString.lowercased())"
    }

    /// iOS-only toolbar button that toggles spam-transaction visibility.
    /// Pinned so a UI test can drive the spam toggle without depending on
    /// the rendered label text (which flips between states).
    public static let spamToggleButton = "transactionlist.toolbar.spamToggle"
  }

  // MARK: - RecentlyAdded

  public enum RecentlyAdded {
    /// Root container of the Recently Added view. Stable post-condition
    /// sentinel after navigating to the import landing page — individual
    /// rows are data-dependent, but the container renders whenever the
    /// view does. Mirrors `TransactionList.container`.
    public static let container = "recentlyadded.container"

    /// Stable per-row handle on an imported-transaction row, keyed by
    /// the transaction's UUID (lowercased). The row's visible content
    /// is wrapped in `.accessibilityElement(children: .combine)` for
    /// VoiceOver, which flattens descendant identifiers (the passive
    /// transfer pill among them) into the combined element; a
    /// row-level identifier is therefore the stable handle a driver
    /// uses to wait on a specific row and to open its macOS context
    /// menu (right-click) for the merge / dismiss actions.
    public static func row(_ id: UUID) -> String {
      "recentlyadded.row.\(id.uuidString.lowercased())"
    }
  }

  // The `TransferDetection` namespace lives in
  // `UITestIdentifiers+TransferDetection.swift`.

  // MARK: - Detail

  public enum Detail {
    /// Payee text field on the transaction detail surface.
    public static let payee = "detail.payee"

    /// Picker that sets the counterpart account for a transfer (the "To
    /// Account" or "From Account" picker depending on `showFromAccount`).
    /// Only rendered when `draft.type == .transfer`.
    public static let toAccountPicker = "detail.toAccountPicker"

    /// Counterpart amount text field. Only rendered when the transfer is
    /// cross-currency (primary and counterpart legs' accounts have
    /// different instruments).
    public static let counterpartAmount = "detail.counterpartAmount"

    /// Instrument code label next to the counterpart amount field (e.g.
    /// "USD"). Rendered in the same row as `counterpartAmount`.
    public static let counterpartAmountInstrument = "detail.counterpartAmount.instrument"

    /// Category text field in the simple-mode (single-leg) category section.
    /// Only rendered when the transaction is in simple (`!isCustom`) mode.
    public static let category = "detail.category"

    /// Category text field inside the given leg section. Only rendered when
    /// the transaction is in multi-leg (`isCustom`) mode.
    public static func legCategory(_ index: Int) -> String {
      "detail.leg.\(index).category"
    }

    /// Picker that selects the transaction type (Income / Expense / Transfer /
    /// Trade / Custom). Only rendered when the transaction is editable (i.e.
    /// not an opening balance and not an irrecoverable custom shape).
    public static let modeTypePicker = "detail.modeTypePicker"

    // MARK: Trade mode identifiers

    /// Account picker in the trade-mode section. Applies to both `.trade` legs
    /// and any fee legs.
    public static let tradeAccount = "transactionDetail.trade.account"

    /// Paid amount text field in the trade-mode section.
    public static let tradePaidAmount = "transactionDetail.trade.paidAmount"

    /// Instrument picker button next to the Paid amount field.
    public static let tradePaidInstrument = "transactionDetail.trade.paidInstrument"

    /// Received amount text field in the trade-mode section.
    public static let tradeReceivedAmount = "transactionDetail.trade.receivedAmount"

    /// Instrument picker button next to the Received amount field.
    public static let tradeReceivedInstrument = "transactionDetail.trade.receivedInstrument"

    /// "+ Add fee" button in the trade-mode section.
    public static let tradeAddFeeButton = "transactionDetail.trade.addFee"

    /// Amount text field for fee leg at `index` (absolute index into `legDrafts`).
    public static func tradeFeeAmount(_ index: Int) -> String {
      "transactionDetail.trade.feeAmount.\(index)"
    }

    /// Remove button for fee leg at `index` (absolute index into `legDrafts`).
    public static func tradeFeeRemove(_ index: Int) -> String {
      "transactionDetail.trade.feeRemove.\(index)"
    }

    /// "View on block explorer" link in the transaction detail. One
    /// row per unique on-chain hash carried by the transaction — for
    /// the typical wallet-imported transaction (transfer + gas legs
    /// sharing one hash), this resolves to a single row.
    public static let blockExplorerLink = "detail.blockExplorer"

    /// Truncated on-chain counterparty address row for the leg at the
    /// given index. Only rendered when the leg has a non-nil
    /// `counterpartyAddress` (recorded by the wallet importer for the
    /// other side of the transfer). The row itself is non-interactive —
    /// the copy button next to it is the only affordance.
    public static func counterpartyAddress(legIndex: Int) -> String {
      "detail.leg.\(legIndex).counterpartyAddress"
    }

    /// "Copy address" button next to the counterparty row for the leg at
    /// the given index.
    public static func counterpartyCopyButton(legIndex: Int) -> String {
      "detail.leg.\(legIndex).counterpartyAddress.copy"
    }
  }

  // MARK: - SyncFooter

  public enum SyncFooter {
    public static let container = "sync.footer.container"
    public static let label = "sync.footer.label"
    public static let detail = "sync.footer.detail"
  }

  // MARK: - Welcome

  public enum Welcome {
    /// "Get started" primary CTA on the first-run hero (states 1 and 4).
    public static let heroGetStartedButton = "welcome.hero.getStarted"
    /// "Create a new profile" alternate CTA shown while iCloud data is
    /// downloading (`.heroDownloading` state). De-emphasised relative to the
    /// normal "Get started" button.
    public static let heroCreateNewButton = "welcome.hero.createNew"
    /// Status line under the hero CTA showing iCloud download progress.
    /// Rendered by `ICloudStatusLine` in the `.checkingActive` state.
    public static let heroDownloadingStatus = "welcome.hero.downloadingStatus"
    /// Footnote below the hero CTA in the `.heroDownloading` state.
    public static let heroDownloadFootnote = "welcome.hero.downloadFootnote"
    /// Name text field in the create-profile form.
    public static let nameField = "welcome.create.nameField"
    /// "Create Profile" submit button in the create-profile form.
    public static let createProfileButton = "welcome.create.createButton"
    /// Identifier prefix shared by all multi-profile picker rows
    /// (`welcome.picker.row.<uuid>`). Use with predicate-based matching
    /// when the test needs to count rows without enumerating UUIDs.
    public static let pickerRowPrefix = "welcome.picker.row."
    /// Profile row in the multi-profile picker. Suffix is the profile UUID,
    /// lowercased.
    public static func pickerRow(_ id: UUID) -> String {
      "\(pickerRowPrefix)\(id.uuidString.lowercased())"
    }
    /// "+ Create a new profile" footer row in the multi-profile picker.
    public static let pickerCreateNewRow = "welcome.picker.createNew"
    /// "Open" action on the single-profile arrival banner.
    public static let bannerOpenAction = "welcome.banner.open"
    /// "View" action on the multi-profile arrival banner.
    public static let bannerViewAction = "welcome.banner.view"
    /// "Dismiss" action on any arrival banner.
    public static let bannerDismissAction = "welcome.banner.dismiss"
    /// "Open System Settings" link on the iCloud-off hero chip.
    public static let iCloudOffSystemSettingsLink = "welcome.off.systemSettings"
  }

  // MARK: - InstrumentPicker

  public enum InstrumentPicker {
    /// The field button that opens the instrument picker sheet. The qualifier
    /// is the currently selected instrument's id (e.g. `"AUD"`, `"USD"`).
    /// When the selection changes the identifier changes, so the post-condition
    /// check after a pick uses the *new* id.
    public static func field(_ id: String) -> String {
      "instrumentPicker.field.\(id)"
    }

    /// The sheet root presented by `InstrumentPickerSheet`. Appears when the
    /// field button is tapped and the CloudKit-backed picker is active.
    public static let sheet = "instrumentPicker.sheet"

    /// The search text field inside the macOS picker popover.
    /// On macOS the picker uses a custom VStack layout with an explicit
    /// `TextField` (so the search input is accessible by identifier) rather
    /// than `.searchable` on a `NavigationStack`, which does not surface an
    /// accessible search field inside a popover.
    public static let searchField = "instrumentPicker.searchField"

    /// A row inside the sheet for a specific instrument. The qualifier is the
    /// instrument id (e.g. `"USD"`).
    public static func row(_ id: String) -> String {
      "instrumentPicker.row.\(id)"
    }
  }

  // MARK: - Settings

  public enum Settings {
    /// Title of the Crypto tab in the macOS Settings TabView. SwiftUI's
    /// `Tab` does not propagate `.accessibilityIdentifier(_:)` to the
    /// generated toolbar button on macOS, so drivers locate the button
    /// by its accessibility label (which mirrors the tab's title) rather
    /// than by an identifier. Centralising the title here keeps the
    /// driver free of raw English literals — the production view and the
    /// driver both reference this constant. If/when `Tab` accessibility
    /// identifiers ship on macOS, swap the screen driver to
    /// `app.element(for:)` and switch this to an identifier value.
    public static let cryptoTabTitle = "Crypto"
  }

  // MARK: - CryptoAccountCreation

  public enum CryptoAccountCreation {
    /// Chain picker (Ethereum / OP Mainnet / Base / Polygon) inside the
    /// crypto branch of `CreateAccountView`. Pinned so a UI test can
    /// switch chains without depending on rendered display names.
    public static let chainPicker = "createAccount.crypto.chainPicker"

    /// Wallet-address text field inside the crypto branch of
    /// `CreateAccountView`. The user pastes a `0x…` address here;
    /// validation lives in `Account.validatedWalletAddress`.
    public static let walletAddressField = "createAccount.crypto.walletAddress"
  }

  // MARK: - ExchangeAccountCreation

  public enum ExchangeAccountCreation {
    /// Provider picker (currently Coinstash) inside the exchange branch
    /// of `CreateAccountView`. Pinned so a UI test can switch providers
    /// without depending on rendered display names.
    public static let providerPicker = "createAccount.exchange.providerPicker"

    /// Read-only API-token `SecureField` inside the exchange branch of
    /// `CreateAccountView`. The user pastes their provider token here;
    /// it is persisted to the keychain via `ExchangeTokenStore`.
    public static let accessTokenField = "createAccount.exchange.accessTokenField"
  }

  // MARK: - CreateCategory

  public enum CreateCategory {
    /// Parent-category autocomplete field in the create-category sheet
    /// reached from the Categories list "+". Pinned so a future UI test
    /// can drive the create flow without depending on rendered text.
    public static let parentCategoryField = "createCategory.parentCategory"
  }

  // The `WalletAccountHeader` namespace lives in
  // `UITestIdentifiers+WalletAccountHeader.swift`.

  // The `CryptoSettings` namespace lives in
  // `UITestIdentifiers+CryptoSettings.swift`.

  // MARK: - EditAccount

  public enum EditAccount {
    /// Valuation-mode picker shown for legacy investment accounts in
    /// `.recordedValue` mode or `.calculatedFromTrades` accounts that
    /// still have at least one `InvestmentValue` snapshot. Identifier
    /// pinned by `EditAccountView.valuationSection`.
    public static let valuationModePicker = "editAccount.valuationMode"

    /// Cancel toolbar button. Drivers click it to dismiss the dialog
    /// after assertions run, AND use it as the presence sentinel for
    /// `expectVisible()` — Cancel is the only element that's
    /// guaranteed to render whenever the dialog opens (the rest of
    /// the form depends on account type and visibility resolver
    /// state). SwiftUI's `.accessibilityIdentifier(_:)` on
    /// `NavigationStack` / `Form` does not propagate to the
    /// macOS-rendered window root, so a content-element sentinel is
    /// the working pattern here.
    public static let cancelButton = "editAccount.cancel"

    /// Save toolbar button. Pinned for symmetry with `cancelButton` so
    /// future tests can exercise the save path through the same
    /// resolver pattern.
    public static let saveButton = "editAccount.save"

    /// Write-only `SecureField` shown only for `.exchange` accounts in
    /// `EditAccountView.exchangeSection`. The user types a new read-only
    /// API token to replace the stored one (blank = keep existing).
    /// Distinct from `ExchangeAccountCreation.accessTokenField`
    /// (`createAccount.exchange.accessTokenField`) so XCUITest matching
    /// never resolves the wrong field across the create/edit surfaces.
    public static let exchangeAccessTokenField = "editAccount.exchange.accessTokenField"
  }

  // MARK: - Autocomplete

  public enum Autocomplete {
    /// Container element of the payee autocomplete dropdown.
    public static let payee = "autocomplete.payee"

    /// Indexed payee suggestion row inside the dropdown.
    public static func payeeSuggestion(_ index: Int) -> String {
      "autocomplete.payee.suggestion.\(index)"
    }

    /// Container element of the simple-mode category autocomplete dropdown.
    /// Only rendered when the transaction is in simple (`!isCustom`) mode.
    public static let category = "autocomplete.category"

    /// Indexed category suggestion row inside the simple-mode dropdown.
    public static func categorySuggestion(_ index: Int) -> String {
      "autocomplete.category.suggestion.\(index)"
    }

    /// Container element of the category autocomplete dropdown for the given
    /// leg. Only one leg's category dropdown is visible at a time; the
    /// identifier reflects whichever leg is active. Only rendered in multi-leg
    /// (`isCustom`) mode.
    public static func legCategory(_ legIndex: Int) -> String {
      "autocomplete.leg.\(legIndex).category"
    }

    /// Indexed category suggestion row inside the given leg's dropdown.
    public static func legCategorySuggestion(_ legIndex: Int, _ rowIndex: Int) -> String {
      "autocomplete.leg.\(legIndex).category.suggestion.\(rowIndex)"
    }
  }
}
