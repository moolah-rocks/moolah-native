import Foundation
import OSLog

/// The "Sync Now" button's in-progress indicator, as decided by
/// `SyncedAccountHeaderLogic.syncButtonProgress(isSyncing:progress:)`.
/// `.none` renders the normal label; `.indeterminate` the existing
/// spinner; `.determinate(fraction)` a `ProgressView(value:)` bar.
enum SyncButtonProgress: Equatable {
  case none
  case indeterminate
  case determinate(Double)
}

/// Pure-logic helper for `SyncedAccountHeaderView`. Owns the relative-
/// time formatting for the last-synced label, the "is sync allowed"
/// predicate, and the user-facing error caption so they are all
/// unit-testable without instantiating a SwiftUI view.
///
/// The sync-enabled predicate and the error caption branch on account
/// type so the same header serves crypto and exchange accounts. The
/// crypto error-caption strings are byte-identical to the
/// `WalletAccountHeaderLogic` contract and must stay so — do not reword
/// a crypto branch without updating its callers/tests.
enum SyncedAccountHeaderLogic {
  private static let logger = Logger(
    subsystem: "com.moolah.app", category: "SyncedAccountHeaderLogic")

  /// User-facing relative-time label for the account's last successful
  /// sync. A `nil` state — or a state whose checkpoint is still the
  /// `.distantPast` sentinel that `persistError` writes for an account
  /// that has never had a successful sync — renders as "Never synced".
  /// Otherwise uses `RelativeDateTimeFormatter.short` and prefixes
  /// "Synced ".
  static func lastSyncedText(state: WalletSyncState?, now: Date) -> String {
    guard let lastSyncedAt = state?.lastSyncedAt, lastSyncedAt != .distantPast else {
      return "Never synced"
    }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    let relative = formatter.localizedString(for: lastSyncedAt, relativeTo: now)
    return "Synced \(relative)"
  }

  /// Whether the "Sync Now" button should be enabled for the given
  /// account. The button collapses to disabled when:
  ///
  /// - The account is already mid-sync (mirrors
  ///   `SyncedAccountStore.syncAccount`'s collapse-duplicates guard so a
  ///   tap during sync isn't a misleading no-op).
  /// - The account's sync credential is absent (crypto: no Alchemy API
  ///   key; exchange: no read-only token). Per design — "Without a valid
  ///   key, sync is disabled with an inline prompt to add one." — the
  ///   button must visibly refuse so the user is steered to the fix
  ///   instead of staring at a credential error caption every tap.
  static func isSyncEnabled(
    accountId: UUID,
    inProgress: Set<UUID>,
    hasCredential: Bool
  ) -> Bool {
    guard hasCredential else { return false }
    return !inProgress.contains(accountId)
  }

  /// "Sync Now" button title given whether the Option (⌥) key is
  /// currently held (macOS only; always `false` on iOS, which has no
  /// modifier keys to hold). Holding Option relabels the button to
  /// signal that the tap will trigger a full re-sync rather than the
  /// default incremental one.
  static func syncButtonTitle(optionHeld: Bool) -> String {
    optionHeld ? "Resync Now" : "Sync Now"
  }

  /// Whether a tap of the "Sync Now" button should request a full
  /// resync (`SyncedAccountStore.syncAccount(_:fullResync:)`). Mirrors
  /// `syncButtonTitle(optionHeld:)` — the two must never disagree, since
  /// a "Resync Now" label promising a full resync that silently does an
  /// incremental one would mislead the user.
  static func syncButtonIsFullResync(optionHeld: Bool) -> Bool {
    optionHeld
  }

  /// What the "Sync Now" button should render for its in-progress
  /// indicator, given whether the account is currently syncing and its
  /// latest `WalletSyncProgress` (`SyncedAccountStore.progressPerAccount`).
  ///
  /// Not syncing always collapses to `.none` regardless of a stale
  /// leftover progress value — the button shows its normal label. While
  /// syncing, a `.scanning(fraction:)` value renders as a determinate bar;
  /// `.indeterminate` (or no progress value published yet, e.g. before the
  /// windowed runner has computed its first fraction) renders as the
  /// existing indeterminate spinner.
  static func syncButtonProgress(
    isSyncing: Bool, progress: WalletSyncProgress?
  ) -> SyncButtonProgress {
    guard isSyncing else { return .none }
    switch progress {
    case .scanning(let fraction):
      return .determinate(fraction)
    case .indeterminate, nil:
      return .indeterminate
    }
  }

  /// Tooltip (`.help`) text for the sync button. While a sync is in
  /// flight the button is disabled, so the tooltip says so rather than
  /// promising an action the tap won't perform; otherwise it mirrors the
  /// button's action — the missing-credential hint when the account can't
  /// sync, or the Option-key-aware sync/resync wording when it can.
  static func syncButtonHelp(
    isSyncing: Bool, hasCredential: Bool, optionHeld: Bool, missingCredentialHint: String?
  ) -> String {
    if isSyncing { return "Sync in progress…" }
    guard hasCredential else {
      return missingCredentialHint ?? "Configure this account to enable sync"
    }
    return optionHeld ? "Resync full history now" : "Sync account now"
  }

  /// VoiceOver *label* (the control's stable identity) for the sync
  /// button given its current `SyncButtonProgress` and whether Option (⌥)
  /// is held. Both in-progress states share the pre-existing "Syncing in
  /// progress" wording so the label doesn't churn as an indeterminate scan
  /// resolves to a determinate one — the changing percentage rides on the
  /// separate `syncButtonAccessibilityValue(for:)` instead (matching the
  /// `.accessibilityLabel` + `.accessibilityValue` + `.updatesFrequently`
  /// idiom used by the other in-progress indicators in this app). `.none`
  /// mirrors the button's action label, which tracks the Option-key resync
  /// toggle.
  static func syncButtonAccessibilityLabel(
    _ progress: SyncButtonProgress, optionHeld: Bool
  ) -> String {
    switch progress {
    case .determinate, .indeterminate:
      return "Syncing in progress"
    case .none:
      return optionHeld ? "Resync full history now" : "Sync account now"
    }
  }

  /// VoiceOver *value* for the sync button — the changing part that
  /// updates frequently while a determinate scan progresses. Only a
  /// `.determinate` scan has a value to report (its whole-percent
  /// completion, e.g. "42%", locale-formatted via `FloatingPointFormatStyle`
  /// so the percent symbol placement follows the user's locale); every
  /// other state returns `nil`, which the view maps to an empty
  /// accessibility value (VoiceOver announces that as no value).
  static func syncButtonAccessibilityValue(
    for progress: SyncButtonProgress
  ) -> String? {
    guard case .determinate(let fraction) = progress else { return nil }
    return fraction.formatted(.percent.precision(.fractionLength(0)))
  }

  /// Synchronous credential presence check, invoked once from the
  /// header's `.task(id:)` (never from `body` — the keychain read would
  /// otherwise fire on every render/scroll frame).
  ///
  /// Returns `true` on a keychain error for exchange accounts: a
  /// locked/unavailable keychain must not nag the user with a "missing
  /// token" hint or disable Sync for a token that may well exist.
  ///
  /// `@MainActor` because `CryptoTokenStore.hasAlchemyApiKey` is
  /// main-actor-isolated; the caller (`.task` on the header view) is
  /// already on the main actor.
  @MainActor
  static func hasCredential(
    for account: Account,
    cryptoTokenStore: CryptoTokenStore?,
    exchangeTokenStore: ExchangeTokenStore
  ) -> Bool {
    switch account.type {
    case .crypto:
      return cryptoTokenStore?.hasAlchemyApiKey ?? false
    case .exchange:
      do { return (try exchangeTokenStore.token(for: account.id)) != nil } catch {
        Self.logger.warning(
          "Keychain unavailable for \(account.id, privacy: .public): \(error, privacy: .public)")
        return true
      }
    case .bank, .creditCard, .asset, .investment:
      return true
    }
  }

  /// User-facing string for a `WalletSyncError` persisted on a per-
  /// account `WalletSyncState`. Returns `nil` when the state has no
  /// error so callers can skip rendering the caption row entirely.
  static func errorCaption(
    for state: WalletSyncState?, account: Account, now: Date = Date()
  ) -> String? {
    guard let error = state?.lastError else { return nil }
    return errorCaption(for: error, account: account, now: now)
  }

  /// Branchless variant on the raw error so unit tests can pin the
  /// message for each case without constructing a `WalletSyncState`.
  ///
  /// When the error is attributed (`error.provider != nil`) the caption
  /// names the failing provider so the user knows which integration broke.
  /// When it is unattributed (`provider == nil` — legacy persisted rows or
  /// errors not tied to one provider) the caption falls back to the
  /// byte-identical pre-attribution strings so the `WalletAccountHeaderLogic`
  /// contract and its characterisation tests keep passing. `.missingApiKey`
  /// stays account-type-driven even when attributed: the actionable "add a
  /// key" instruction gains nothing from a provider prefix.
  static func errorCaption(
    for error: WalletSyncError, account: Account, now: Date = Date()
  ) -> String {
    switch error.kind {
    case .missingApiKey:
      return missingApiKeyCaption(account: account)
    case .invalidApiKey:
      return invalidApiKeyCaption(provider: error.provider, account: account)
    case .rateLimited(let retryAfter):
      return rateLimitedCaption(provider: error.provider, retryAfter: retryAfter, now: now)
    case .network(let underlying):
      return networkCaption(provider: error.provider, underlying: underlying)
    case .providerMalformedResponse(let stage):
      return malformedCaption(provider: error.provider, stage: stage)
    case let .providerError(stage, _, message):
      return providerErrorCaption(provider: error.provider, stage: stage, message: message)
    }
  }
}

extension SyncedAccountHeaderLogic {
  private static func missingApiKeyCaption(account: Account) -> String {
    switch account.type {
    case .exchange:
      return "Add your read-only API token to sync."
    case .crypto, .bank, .creditCard, .asset, .investment:
      return "Add an Alchemy API key to enable sync."
    }
  }

  /// Attributed → provider name; unattributed → account-type legacy wording.
  private static func invalidApiKeyCaption(
    provider: SyncProvider?, account: Account
  ) -> String {
    if let provider {
      return "\(provider.displayName) rejected the API token."
    }
    switch account.type {
    case .exchange:
      let provider = account.exchangeProvider?.displayName ?? "The exchange"
      return "\(provider) rejected the API token."
    case .crypto, .bank, .creditCard, .asset, .investment:
      return "Alchemy rejected the API key."
    }
  }

  private static func rateLimitedCaption(
    provider: SyncProvider?, retryAfter: Date?, now: Date
  ) -> String {
    let prefix: String
    if let provider {
      prefix = "\(provider.displayName) rate-limited"
    } else {
      prefix = "Rate-limited"
    }
    guard let retryAfter else { return "\(prefix). Retry shortly." }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return
      "\(prefix). Retry \(formatter.localizedString(for: retryAfter, relativeTo: now))."
  }

  private static func networkCaption(
    provider: SyncProvider?, underlying: String
  ) -> String {
    if let provider {
      return "\(provider.displayName) network error: \(underlying)."
    }
    return "Network error: \(underlying)"
  }

  private static func malformedCaption(
    provider: SyncProvider?, stage: String
  ) -> String {
    if let provider {
      return "\(provider.displayName) returned a malformed response (\(stage))."
    }
    return "Provider returned a malformed response (\(stage))."
  }

  /// Surfaces the provider's own refusal reason (e.g. "pruned history
  /// unavailable") rather than a generic "malformed response", so the user
  /// can act on it — switch endpoints, add a key, or use an archive node.
  private static func providerErrorCaption(
    provider: SyncProvider?, stage: String, message: String
  ) -> String {
    if let provider {
      return "\(provider.displayName) couldn't complete sync (\(stage)): \(message)"
    }
    return "Sync failed (\(stage)): \(message)"
  }
}
