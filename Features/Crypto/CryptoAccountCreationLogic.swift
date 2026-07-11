// Features/Crypto/CryptoAccountCreationLogic.swift
import Foundation

/// Pure form-logic helper for the crypto branch of `CreateAccountView`.
/// Owns the create-account + kick-off-sync sequence so the parent view
/// can dispatch from its Save button without relying on a transient
/// SwiftUI view instance, and so `CryptoAccountCreationStoreTests` can
/// exercise the contract end-to-end against `TestBackend`.
@MainActor
struct CryptoAccountCreationLogic {
  let accountStore: AccountStore
  /// May be `nil` in degraded launches (preview / no instrument
  /// registry). When `nil`, account creation still proceeds; the first
  /// sync simply isn't kicked off — the next scenePhase `.active`
  /// stale-check will pick it up.
  let cryptoSyncStore: SyncedAccountStore?
  /// Denominating the account in the profile currency (rather than the
  /// chain's native token) lets a wallet's reported value sit alongside
  /// every other account in one currency, and lets a single account
  /// span multiple tokens without picking an arbitrary "primary" token.
  /// The native-token positions still accrue from leg aggregation; they
  /// are converted into this instrument for the account's reported value.
  let accountInstrument: Instrument

  /// Output of `submit(name:chain:walletAddressInput:)`. The parent
  /// surface uses `.created` to dismiss the sheet and `.failure` /
  /// `.invalidAddress` to show an inline error message.
  enum Outcome: Sendable {
    case created(Account)
    case invalidAddress
    case failure(Error)
  }

  /// Persists the new crypto account and kicks off its first sync.
  /// Returns the outcome rather than mutating shared state directly so
  /// the parent view can decide how to surface success vs failure.
  func submit(
    name: String,
    chain: ChainConfig,
    walletAddressInput: String,
    taxOwnerIds: [UUID] = []
  ) async -> Outcome {
    guard let walletAddress = Account.validatedWalletAddress(walletAddressInput) else {
      return .invalidAddress
    }
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else { return .invalidAddress }

    let account = Account(
      name: trimmedName,
      type: .crypto,
      instrument: accountInstrument,
      valuationMode: .calculatedFromTrades,
      walletAddress: walletAddress,
      chainId: chain.chainId,
      taxOwnerIds: taxOwnerIds
    )

    do {
      let created = try await accountStore.create(account)
      // Kick off the initial sync without awaiting so the parent sheet
      // can `dismiss()` the moment the account is persisted instead of
      // sitting open through the entire network round-trip. The store
      // tracks the spawned task so it's cancelled on profile teardown
      // and collapses with the next scenePhase `.active` trigger
      // rather than queueing a redundant pass. A `nil` `cryptoSyncStore`
      // (degraded launch) leaves the account stale; the next
      // stale-sync pass picks it up.
      cryptoSyncStore?.scheduleInitialSync(for: created)
      return .created(created)
    } catch {
      return .failure(error)
    }
  }
}
