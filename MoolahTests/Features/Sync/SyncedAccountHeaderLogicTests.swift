// MoolahTests/Features/Sync/SyncedAccountHeaderLogicTests.swift
import Foundation
import Testing

@testable import Moolah

/// Pure-logic tests for `SyncedAccountHeaderLogic` — the relative-time
/// formatting for the last-synced label, the "is sync allowed"
/// predicate, and the user-facing error caption. These are the
/// load-bearing pieces of the synced-account header; the SwiftUI
/// rendering itself is exercised via preview snapshots and the UI
/// driver suite.
///
/// Characterisation: the crypto-string assertions here are byte-identical
/// to the `WalletAccountHeaderLogic` contract and must remain so.
@Suite("SyncedAccountHeaderLogic")
struct SyncedAccountHeaderLogicTests {
  private let cryptoAccount = Account(
    name: "W", type: .crypto, instrument: .AUD,
    walletAddress: "0xabc", chainId: 1)
  private let exchangeAccount = Account(
    name: "C", type: .exchange, instrument: .AUD,
    exchangeProvider: .coinstash)

  // MARK: - Last-synced text

  @Test("Nil sync state renders as 'Never synced'")
  func neverSyncedWhenStateAbsent() {
    let label = SyncedAccountHeaderLogic.lastSyncedText(state: nil, now: Date())
    #expect(label == "Never synced")
  }

  @Test("Recent sync renders with the 'Synced ' prefix")
  func recentSyncIsPrefixedWithSynced() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let oneMinuteAgo = now.addingTimeInterval(-60)
    let state = WalletSyncState(
      id: UUID(), lastSyncedBlockNumber: 0, lastSyncedAt: oneMinuteAgo, lastError: nil)
    let label = SyncedAccountHeaderLogic.lastSyncedText(state: state, now: now)
    #expect(label.hasPrefix("Synced "))
    // The locale-specific RelativeDateTimeFormatter output isn't a stable
    // assertion target across CI environments — we pin only the prefix
    // and that the label is non-empty after the space.
    #expect(label.count > "Synced ".count)
  }

  @Test("Two-hour-old sync uses a non-empty relative description")
  func twoHourOldSyncHasNonEmptyDescription() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let twoHoursAgo = now.addingTimeInterval(-7_200)
    let state = WalletSyncState(
      id: UUID(), lastSyncedBlockNumber: 1_234, lastSyncedAt: twoHoursAgo, lastError: nil)
    let label = SyncedAccountHeaderLogic.lastSyncedText(state: state, now: now)
    #expect(label.hasPrefix("Synced "))
    let trailing = label.dropFirst("Synced ".count)
    #expect(!trailing.isEmpty)
  }

  @Test("State with a .distantPast checkpoint renders as 'Never synced'")
  func neverSyncedWhenCheckpointIsDistantPast() {
    // persistError writes lastSyncedAt: .distantPast for an account that
    // has never had a successful sync (e.g. the first attempt failed).
    // That sentinel must read as "Never synced", not "Synced 2025 years ago".
    let state = WalletSyncState(
      id: UUID(), lastSyncedBlockNumber: 0, lastSyncedAt: .distantPast, lastError: nil)
    let label = SyncedAccountHeaderLogic.lastSyncedText(state: state, now: Date())
    #expect(label == "Never synced")
  }

  // MARK: - Sync-now enabled state

  @Test("Sync-now button enabled when account is not in flight and a credential is configured")
  func syncEnabledWhenNotInFlight() {
    let id = UUID()
    #expect(
      SyncedAccountHeaderLogic.isSyncEnabled(
        accountId: id, inProgress: [], hasCredential: true))
    #expect(
      SyncedAccountHeaderLogic.isSyncEnabled(
        accountId: id, inProgress: [UUID()], hasCredential: true))
  }

  @Test("Sync-now button disabled while account is in flight")
  func syncDisabledWhenInFlight() {
    let id = UUID()
    #expect(
      !SyncedAccountHeaderLogic.isSyncEnabled(
        accountId: id, inProgress: [id], hasCredential: true))
  }

  @Test("Sync-now button disabled when no credential is configured")
  func syncDisabledWhenNoCredential() {
    let id = UUID()
    // Even idle and otherwise eligible, no credential → no sync.
    #expect(
      !SyncedAccountHeaderLogic.isSyncEnabled(
        accountId: id, inProgress: [], hasCredential: false))
    // And in-flight + no credential still resolves to disabled.
    #expect(
      !SyncedAccountHeaderLogic.isSyncEnabled(
        accountId: id, inProgress: [id], hasCredential: false))
  }

  // MARK: - Sync button title / full-resync intent (Option-key toggle)

  @Test("Option held renders the resync title and requests a full resync")
  func syncButtonTitleWhenOptionHeld() {
    #expect(SyncedAccountHeaderLogic.syncButtonTitle(optionHeld: true) == "Resync Now")
    #expect(SyncedAccountHeaderLogic.syncButtonIsFullResync(optionHeld: true))
  }

  @Test("Option not held renders the default title and does not request a full resync")
  func syncButtonTitleWhenOptionNotHeld() {
    #expect(SyncedAccountHeaderLogic.syncButtonTitle(optionHeld: false) == "Sync Now")
    #expect(!SyncedAccountHeaderLogic.syncButtonIsFullResync(optionHeld: false))
  }

  // MARK: - Inline error caption

  @Test("Nil lastError yields no inline error caption")
  func errorCaptionAbsentWhenNoError() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let state = WalletSyncState(
      id: UUID(),
      lastSyncedBlockNumber: 100,
      lastSyncedAt: now.addingTimeInterval(-60),
      lastError: nil)
    #expect(SyncedAccountHeaderLogic.errorCaption(for: state, account: cryptoAccount) == nil)
    #expect(SyncedAccountHeaderLogic.errorCaption(for: nil, account: cryptoAccount) == nil)
  }

  // MARK: - Crypto error captions (characterisation: byte-verbatim)

  @Test("Crypto .invalidApiKey keeps the verbatim Alchemy caption")
  func cryptoInvalidApiKeyCaption() {
    #expect(
      SyncedAccountHeaderLogic.errorCaption(for: .invalidApiKey, account: cryptoAccount)
        == "Alchemy rejected the API key.")
  }

  @Test("Crypto .missingApiKey keeps the verbatim Alchemy caption")
  func cryptoMissingApiKeyCaption() {
    #expect(
      SyncedAccountHeaderLogic.errorCaption(for: .missingApiKey, account: cryptoAccount)
        == "Add an Alchemy API key to enable sync.")
  }

  @Test("Crypto .invalidApiKey through a state yields the verbatim caption")
  func cryptoInvalidApiKeyCaptionViaState() {
    let state = WalletSyncState(
      id: UUID(), lastSyncedBlockNumber: 0, lastSyncedAt: .distantPast,
      lastError: .invalidApiKey)
    #expect(
      SyncedAccountHeaderLogic.errorCaption(for: state, account: cryptoAccount)
        == "Alchemy rejected the API key.")
  }

  // MARK: - Exchange error captions (provider-displayName interpolated)

  @Test("Exchange .invalidApiKey interpolates the provider display name")
  func exchangeInvalidApiKeyCaption() {
    #expect(
      SyncedAccountHeaderLogic.errorCaption(for: .invalidApiKey, account: exchangeAccount)
        == "Coinstash rejected the API token.")
  }

  @Test("Exchange .missingApiKey uses the read-only-token caption")
  func exchangeMissingApiKeyCaption() {
    #expect(
      SyncedAccountHeaderLogic.errorCaption(for: .missingApiKey, account: exchangeAccount)
        == "Add your read-only API token to sync.")
  }

  // MARK: - Generic (account-neutral) captions unchanged

  @Test("Network error caption is account-neutral and unchanged")
  func networkCaptionUnchanged() {
    #expect(
      SyncedAccountHeaderLogic.errorCaption(
        for: .network(underlyingDescription: "boom"), account: cryptoAccount)
        == "Network error: boom")
    #expect(
      SyncedAccountHeaderLogic.errorCaption(
        for: .network(underlyingDescription: "boom"), account: exchangeAccount)
        == "Network error: boom")
  }

  @Test("Malformed-response caption is account-neutral and unchanged")
  func malformedCaptionUnchanged() {
    #expect(
      SyncedAccountHeaderLogic.errorCaption(
        for: .providerMalformedResponse(stage: "decode"), account: exchangeAccount)
        == "Provider returned a malformed response (decode).")
  }

  // MARK: - Provider-attributed captions

  @Test("Attributed invalidApiKey names the provider")
  func attributedInvalidApiKeyNamesProvider() {
    let error = WalletSyncError(provider: .coinstash, kind: .invalidApiKey)
    let caption = SyncedAccountHeaderLogic.errorCaption(
      for: error, account: exchangeAccount)
    #expect(caption == "Coinstash rejected the API token.")
  }

  @Test("Attributed network error is prefixed with the provider")
  func attributedNetworkNamesProvider() {
    let error = WalletSyncError(
      provider: .blockExplorer, kind: .network(underlyingDescription: "timeout"))
    let caption = SyncedAccountHeaderLogic.errorCaption(
      for: error, account: cryptoAccount)
    #expect(caption == "Blockscout network error: timeout.")
  }

  @Test("Attributed rateLimited with a retry date names the provider deterministically")
  func attributedRateLimitedWithDateNamesProvider() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let retry = now.addingTimeInterval(120)
    let error = WalletSyncError(provider: .binance, kind: .rateLimited(retryAfter: retry))
    let caption = SyncedAccountHeaderLogic.errorCaption(
      for: error, account: cryptoAccount, now: now)
    // The locale-specific RelativeDateTimeFormatter tail isn't a stable
    // assertion target across CI locales — pin only the deterministic prefix.
    #expect(caption.hasPrefix("Binance rate-limited. Retry "))
  }

  @Test("Unattributed network error keeps the legacy byte-identical string")
  func unattributedNetworkIsByteIdentical() {
    let error = WalletSyncError(
      provider: nil, kind: .network(underlyingDescription: "timeout"))
    let caption = SyncedAccountHeaderLogic.errorCaption(
      for: error, account: cryptoAccount)
    #expect(caption == "Network error: timeout")
  }

  @Test("Unattributed crypto invalidApiKey keeps the legacy Alchemy string")
  func unattributedCryptoInvalidApiKeyIsLegacy() {
    let error = WalletSyncError(provider: nil, kind: .invalidApiKey)
    let caption = SyncedAccountHeaderLogic.errorCaption(
      for: error, account: cryptoAccount)
    #expect(caption == "Alchemy rejected the API key.")
  }
}
