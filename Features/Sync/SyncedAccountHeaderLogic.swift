import Foundation
import OSLog

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

  /// Whether the "Sync now" button should be enabled for the given
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

  /// "Sync now" button title given whether the Option (⌥) key is
  /// currently held (macOS only; always `false` on iOS, which has no
  /// modifier keys to hold). Holding Option relabels the button to
  /// signal that the tap will trigger a full re-sync rather than the
  /// default incremental one.
  static func syncButtonTitle(optionHeld: Bool) -> String {
    optionHeld ? "Resync Now" : "Sync now"
  }

  /// Whether a tap of the "Sync now" button should request a full
  /// resync (`SyncedAccountStore.syncAccount(_:fullResync:)`). Mirrors
  /// `syncButtonTitle(optionHeld:)` — the two must never disagree, since
  /// a "Resync Now" label promising a full resync that silently does an
  /// incremental one would mislead the user.
  static func syncButtonIsFullResync(optionHeld: Bool) -> Bool {
    optionHeld
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
}
