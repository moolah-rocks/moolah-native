import Foundation
import SwiftUI

/// Compact header for a syncable account (`AccountType.crypto` or
/// `.exchange`). All account-type branching lives in
/// `SyncableAccountPresentation` so this view stays provider-agnostic.
/// Renders:
///
/// - For crypto: the full wallet address in a monospaced, selectable
///   font with a copy button. The address is **never** truncated in
///   that section — a truncated `0x1234…abcd` is unsafe to verify
///   against because an attacker can mine a vanity address with
///   matching prefix and suffix.
/// - A single status row: a context label (chain name for crypto — the
///   untruncated address already appears above, so no truncated copy is
///   shown here; provider name for exchange) and an inline "open
///   externally" link (block explorer / provider website) on the
///   leading edge, with the last-synced relative timestamp ("Synced 2h
///   ago" / "Never synced") and the "Sync now" button trailing on the
///   *same* line. The button calls `syncStore.syncAccount(account)` and
///   is disabled while a sync is in flight or the account's credential
///   is missing. On macOS, holding Option (⌥) relabels the button to
///   "Resync Now" and switches the tap to a full resync
///   (`fullResync: true`); iOS has no modifier keys, so the button there
///   always performs the default incremental sync.
///
/// Pure presentation: every piece of business logic that benefits from
/// unit testing (last-synced formatting, sync button state, error
/// caption, credential presence) lives in `SyncedAccountHeaderLogic`.
struct SyncedAccountHeaderView: View {
  let account: Account
  let syncStore: SyncedAccountStore

  /// Token stores used once (in `.task`) to compute `hasCredential`.
  /// Crypto reads the Alchemy key off `CryptoTokenStore`; exchange
  /// reads the per-account token off `ExchangeTokenStore`.
  let cryptoTokenStore: CryptoTokenStore?
  let exchangeTokenStore: ExchangeTokenStore

  /// Closure used to copy the supplied string to the system pasteboard.
  /// Defaulted to the platform's standard pasteboard so production code
  /// has a single sensible default; tests / previews override.
  /// `@MainActor` because the production defaults call `NSPasteboard` /
  /// `UIPasteboard`, both of which are main-actor-isolated.
  let copyToPasteboard: @MainActor (String) -> Void

  /// Closure used to open a URL in the user's default browser.
  /// Defaulted to the platform-standard handler; tests override.
  /// `@MainActor` for the same reason as `copyToPasteboard`.
  let openExternalURL: @MainActor (URL) -> Void

  /// Credential presence (Alchemy key / exchange token). Read once via
  /// `.task(id:)` — never in `body` (the keychain lookup would
  /// otherwise fire on every render/scroll frame). Defaults to `true`
  /// so the header doesn't flash a "missing credential" state before
  /// the task runs, and matches the optimistic-on-keychain-error intent.
  @State private var hasCredential = true

  /// Whether the Option (⌥) key is currently held. macOS-only — iOS has
  /// no modifier keys to hold, so this stays permanently `false` there
  /// and the sync button keeps its plain, non-toggling behaviour.
  /// Tracked live (not just at tap time) so the button's label updates
  /// the instant the user presses/releases Option, before they click.
  #if os(macOS)
    @State private var optionHeld = false
  #endif

  init(
    account: Account,
    syncStore: SyncedAccountStore,
    cryptoTokenStore: CryptoTokenStore?,
    exchangeTokenStore: ExchangeTokenStore,
    copyToPasteboard: @escaping @MainActor (String) -> Void = SyncedAccountHeaderView.defaultCopy,
    openExternalURL: @escaping @MainActor (URL) -> Void = SyncedAccountHeaderView.defaultOpen
  ) {
    self.account = account
    self.syncStore = syncStore
    self.cryptoTokenStore = cryptoTokenStore
    self.exchangeTokenStore = exchangeTokenStore
    self.copyToPasteboard = copyToPasteboard
    self.openExternalURL = openExternalURL
  }

  private var address: String { account.walletAddress ?? "" }

  private var syncState: WalletSyncState? {
    syncStore.statePerAccount[account.id]
  }

  /// Relative last-synced label for a given clock instant. `now` is
  /// supplied by the enclosing `TimelineView` (see `statusRow`) so the
  /// label ticks on the timeline's cadence rather than being frozen at
  /// the last unrelated re-render. The formatting itself stays in the
  /// unit-tested `SyncedAccountHeaderLogic`.
  private func lastSyncedText(now: Date) -> String {
    SyncedAccountHeaderLogic.lastSyncedText(state: syncState, now: now)
  }

  private var isSyncing: Bool {
    syncStore.inProgressAccountIds.contains(account.id)
  }

  /// `optionHeld` collapsed to a cross-platform read: iOS has no
  /// modifier keys, so it reads permanently `false` there without the
  /// call sites below needing their own `#if os(macOS)`.
  private var isOptionHeld: Bool {
    #if os(macOS)
      optionHeld
    #else
      false
    #endif
  }

  /// Per-account error caption (red), or `nil` when the most recent
  /// build phase succeeded.
  private var errorCaption: String? {
    SyncedAccountHeaderLogic.errorCaption(for: syncState, account: account)
  }

  private var presentation: SyncableAccountPresentation {
    SyncableAccountPresentation(account: account, hasCredential: hasCredential)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if account.type == .crypto {
        addressSection
      }
      statusRow(presentation)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.regularMaterial)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(UITestIdentifiers.WalletAccountHeader.container)
    .task(id: account.id) {
      hasCredential = SyncedAccountHeaderLogic.hasCredential(
        for: account,
        cryptoTokenStore: cryptoTokenStore,
        exchangeTokenStore: exchangeTokenStore)
    }
  }
}

// MARK: - Layout helpers

extension SyncedAccountHeaderView {
  /// Single-line status row. Leading edge: a context label + the
  /// inline "open externally" link. Trailing edge: the last-synced
  /// timestamp and the "Sync now" button — all on one line, so the
  /// header is a single row for exchange and exactly two for crypto
  /// (the extra row being only the untruncated address).
  ///
  /// For crypto the label is the chain name: the untruncated wallet
  /// address is shown on its own line by `addressSection`, so repeating
  /// a *truncated* copy here would be both redundant and (truncated)
  /// unsafe to verify against. For exchange there is no address line,
  /// so the label is the provider name. `secondaryIdentifier ??
  /// identifier` resolves to the chain for crypto and the provider for
  /// exchange (and degrades to the truncated address only if a crypto
  /// account has no recognised chain) without the view branching on
  /// `account.type` — that branching stays in
  /// `SyncableAccountPresentation`.
  private func statusRow(_ presentation: SyncableAccountPresentation) -> some View {
    // The caption (missing-credential hint takes precedence over sync
    // error — same rule as `body`) rides inline in the status row's empty
    // middle when everything fits on one line; at cramped widths /
    // accessibility Dynamic Type it drops to its own row.
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        statusLeadingGroup(presentation)
        inlineCaption(presentation)
        Spacer(minLength: 12)
        statusTrailingGroup(presentation)
      }
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 12) {
          statusLeadingGroup(presentation)
          Spacer(minLength: 0)
        }
        inlineCaption(presentation)
        HStack(spacing: 12) {
          statusTrailingGroup(presentation)
          Spacer(minLength: 0)
        }
      }
    }
  }

  /// The missing-credential hint (precedence) or the sync-error caption,
  /// or `EmptyView` when neither applies. Reused in both `ViewThatFits`
  /// branches so the same element renders inline or wrapped.
  @ViewBuilder
  private func inlineCaption(_ presentation: SyncableAccountPresentation) -> some View {
    if let hint = presentation.missingCredentialHint {
      missingCredentialHint(hint)
    } else if let errorCaption {
      errorCaptionView(errorCaption)
    }
  }

  /// Leading half of the status row: the context label and the inline
  /// "open externally" link. Shared by both `ViewThatFits` branches.
  @ViewBuilder
  private func statusLeadingGroup(_ presentation: SyncableAccountPresentation) -> some View {
    // The label is its own VoiceOver stop; the external Link stays a
    // separate focusable action rather than being folded into it.
    Text(presentation.secondaryIdentifier ?? presentation.identifier)
      .font(.caption)
      .foregroundStyle(.secondary)
      .accessibilityIdentifier(UITestIdentifiers.WalletAccountHeader.chainName)
    if let url = presentation.externalURL,
      let title = presentation.externalActionTitle
    {
      Link(title, destination: url)
        .font(.caption)
    }
  }

  /// Trailing half of the status row: the last-synced timestamp and the
  /// "Sync now" button. Shared by both `ViewThatFits` branches.
  @ViewBuilder
  private func statusTrailingGroup(_ presentation: SyncableAccountPresentation) -> some View {
    // `context.date` ticks every 60s on the timeline's schedule, so
    // the relative label ("Synced 3 min ago") stays fresh without an
    // unrelated re-render. `.id(context.date)` forces the `Text` to
    // re-evaluate on each tick. Mirrors `SyncProgressFooter`.
    TimelineView(.periodic(from: .now, by: 60)) { context in
      Text(lastSyncedText(now: context.date))
        // Matches the context label's `.caption`: the timestamp is
        // peer metadata, not a higher tier. `.monospacedDigit()` keeps
        // the relative-time string from jittering as it updates.
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .accessibilityIdentifier(UITestIdentifiers.WalletAccountHeader.lastSynced)
        .id(context.date)
    }
    syncButton(presentation)
  }

  /// Inline prompt rendered when the account's sync credential is
  /// absent. For crypto, pairs the hint with a `SettingsLink` so the
  /// user can jump straight to Crypto preferences; exchange has no
  /// `SettingsLink` (its fix is editing the account, surfaced
  /// elsewhere).
  private func missingCredentialHint(_ hint: String) -> some View {
    HStack(spacing: 6) {
      // Icon + hint text form one VoiceOver stop. The icon is
      // decorative (hidden from VoiceOver); only this subgroup is
      // combined so the macOS `SettingsLink` stays independently
      // activatable.
      HStack(spacing: 6) {
        Image(systemName: "key.slash")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text(hint)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .accessibilityElement(children: .combine)
      // `SettingsLink` is macOS-only and crypto-only. iOS users
      // navigate to Crypto preferences from the app's settings tab;
      // the hint copy alone is enough on that platform.
      #if os(macOS)
        if account.type == .crypto {
          SettingsLink {
            Text("Open preferences")
          }
          .buttonStyle(.borderless)
          .controlSize(.small)
          .accessibilityIdentifier(UITestIdentifiers.WalletAccountHeader.missingApiKeyHintLink)
        }
      #endif
      Spacer(minLength: 0)
    }
    .accessibilityIdentifier(UITestIdentifiers.WalletAccountHeader.missingApiKeyHint)
  }

  /// Inline error caption rendered when `WalletSyncState.lastError`
  /// is non-nil. Red `.caption`.
  private func errorCaptionView(_ caption: String) -> some View {
    Text(caption)
      .font(.caption)
      .foregroundStyle(.red)
      // Sighted users get the error affordance from the red colour;
      // give VoiceOver the same signal since the message text itself
      // carries no "error" marker.
      .accessibilityLabel("Error: \(caption)")
      .accessibilityIdentifier(UITestIdentifiers.WalletAccountHeader.errorCaption)
  }

  private var addressSection: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(address)
        .font(.body.monospaced())
        // The address is never truncated (a clipped 0x1234…abcd is
        // unsafe to verify), so at large Dynamic Type sizes it must
        // wrap, not clip. The cap is one stop below the app-wide
        // `.accessibility3` ceiling: this is an unbreakable 42-char
        // monospace token, and past `.accessibility2` it wraps to four-
        // plus lines and dominates the header without aiding legibility.
        // `.fixedSize` keeps truncation risk at zero regardless.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
        .accessibilityIdentifier(UITestIdentifiers.WalletAccountHeader.address)
        .accessibilityLabel("Wallet address \(address)")
      Button {
        copyToPasteboard(address)
      } label: {
        Label("Copy address", systemImage: "doc.on.doc")
          .labelStyle(.iconOnly)
      }
      .buttonStyle(.borderless)
      .help("Copy full wallet address")
      .accessibilityLabel("Copy wallet address")
      .accessibilityHint(address.isEmpty ? "No wallet address configured" : "")
      .accessibilityIdentifier(UITestIdentifiers.WalletAccountHeader.copyAddressButton)
      .disabled(address.isEmpty)
      Spacer(minLength: 0)
    }
  }

  /// The "Sync now" button. On macOS, holding Option (⌥) relabels it to
  /// "Resync Now" and switches its tap to a full resync
  /// (`syncAccount(_:fullResync: true)`) — an escape hatch for accounts
  /// whose incrementally-synced history has drifted, without cluttering
  /// the default path with a second always-visible button. The
  /// label/action mapping itself lives in `SyncedAccountHeaderLogic` so
  /// it's unit-testable without the AppKit event plumbing; this method
  /// only wires up live Option-key tracking. iOS has no modifier keys,
  /// so `isOptionHeld` reads permanently `false` there and the button
  /// keeps its original plain behaviour.
  private func syncButton(_ presentation: SyncableAccountPresentation) -> some View {
    Button {
      Task {
        await syncStore.syncAccount(
          account,
          fullResync: SyncedAccountHeaderLogic.syncButtonIsFullResync(optionHeld: isOptionHeld))
      }
    } label: {
      if isSyncing {
        ProgressView().controlSize(.small)
      } else {
        Label(
          SyncedAccountHeaderLogic.syncButtonTitle(optionHeld: isOptionHeld),
          systemImage: "arrow.clockwise")
      }
    }
    .disabled(
      !SyncedAccountHeaderLogic.isSyncEnabled(
        accountId: account.id,
        inProgress: syncStore.inProgressAccountIds,
        hasCredential: presentation.hasCredential)
    )
    .buttonStyle(.borderless)
    .help(
      presentation.hasCredential
        ? (isOptionHeld ? "Resync full history now" : "Sync account now")
        : (presentation.missingCredentialHint ?? "Configure this account to enable sync")
    )
    .accessibilityLabel(
      isSyncing
        ? "Syncing in progress"
        : (isOptionHeld ? "Resync full history now" : "Sync account now")
    )
    .accessibilityIdentifier(UITestIdentifiers.WalletAccountHeader.syncButton)
    #if os(macOS)
      .onModifierKeysChanged(mask: .option) { _, modifiers in
        optionHeld = modifiers.contains(.option)
      }
    #endif
  }
}
