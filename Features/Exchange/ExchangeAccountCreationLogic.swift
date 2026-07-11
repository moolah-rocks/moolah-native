// Features/Exchange/ExchangeAccountCreationLogic.swift
import Foundation
import OSLog

/// Pure form-logic helper for the exchange branch of `CreateAccountView`.
/// Owns the create-account + store-token + kick-off-sync sequence so the
/// parent view can dispatch from its Create button without relying on a
/// transient SwiftUI view instance, and so
/// `ExchangeAccountCreationLogicTests` can exercise the contract — including
/// the token-save rollback — end-to-end against `TestBackend`.
///
/// Mirrors `CryptoAccountCreationLogic`: validate → create → kick off the
/// shared `SyncedAccountStore` initial sync. The extra step here is the
/// keychain token write; if it fails the just-created account is rolled
/// back so the user is never left with a "missing token" orphan that can't
/// be repaired from the create sheet.
@MainActor
struct ExchangeAccountCreationLogic {
  private let accountStore: AccountStore
  private let tokenStore: any ExchangeTokenStoring
  /// May be `nil` in degraded launches (preview / no instrument registry),
  /// exactly as `CryptoAccountCreationLogic.cryptoSyncStore` is. When `nil`,
  /// creation still proceeds; the first sync is picked up by the next
  /// scenePhase `.active` stale-check.
  private let syncStore: SyncedAccountStore?
  /// The profile's currency — the new account is denominated in it, NOT a
  /// hardcoded `.AUD` (a non-AUD profile would otherwise mis-denominate).
  /// Per-instrument positions still emerge from leg aggregation converted
  /// into this instrument as exchange syncs land.
  private let profileInstrument: Instrument
  private static let logger = Logger(
    subsystem: "com.moolah.app", category: "ExchangeAccountCreation")

  init(
    accountStore: AccountStore,
    tokenStore: any ExchangeTokenStoring,
    syncStore: SyncedAccountStore?,
    profileInstrument: Instrument
  ) {
    self.accountStore = accountStore
    self.tokenStore = tokenStore
    self.syncStore = syncStore
    self.profileInstrument = profileInstrument
  }

  /// Output of `submit(name:provider:token:)`. The parent surface uses
  /// `.created` to dismiss the sheet and `.failure` / `.invalidInput` to
  /// show an inline error message.
  enum Outcome: Sendable {
    case created(Account)
    case invalidInput
    case failure(Error)
  }

  /// Persists the new exchange account, stores its read-only token, and
  /// kicks off the first sync. Returns the outcome rather than mutating
  /// shared state directly so the parent view can decide how to surface
  /// success vs failure.
  func submit(
    name: String,
    provider: ExchangeProvider,
    token: String,
    taxOwnerIds: [UUID] = []
  ) async -> Outcome {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty, !trimmedToken.isEmpty else {
      return .invalidInput
    }

    let account = Account(
      name: trimmedName,
      type: .exchange,
      instrument: profileInstrument,
      valuationMode: .calculatedFromTrades,
      exchangeProvider: provider,
      taxOwnerIds: taxOwnerIds)

    let created: Account
    do {
      created = try await accountStore.create(account)
    } catch {
      return .failure(error)
    }

    do {
      try tokenStore.save(token: trimmedToken, for: created.id)
    } catch {
      // Roll back the just-created account: an account with no token is
      // stuck "missing token" forever and can't be fixed from this sheet.
      // If the rollback itself fails, log and still surface the original
      // save error — better an orphan we logged than a silent success.
      do {
        try await accountStore.delete(id: created.id)
      } catch {
        Self.logger.error(
          "Rollback delete failed for \(created.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
      }
      return .failure(error)
    }

    // Tracked + cancellable, like `CryptoAccountCreationLogic` — not a bare
    // `Task {}` (which would orphan on sheet dismiss / profile teardown).
    // A `nil` `syncStore` (degraded launch) leaves the account stale; the
    // next stale-sync pass picks it up.
    syncStore?.scheduleInitialSync(for: created)
    return .created(created)
  }
}
