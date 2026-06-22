// MoolahTests/Features/Exchange/ExchangeCreationHarness.swift
import Foundation

@testable import Moolah

/// Shared scaffolding for the exchange-account test suites
/// (`ExchangeAccountCreationLogicTests`, `EditExchangeAccountTests`).
///
/// Provides an in-memory backend giving an `AccountStore` + its
/// `repository`, a token store (real device-local `ExchangeTokenStore`,
/// or a save-throwing double when `failingTokenStore: true`), and an
/// optional `SyncedAccountStore`. The happy path uses a real
/// `ExchangeTokenStore(synchronizable: false)` (device-local keychain,
/// no entitlement) so token round-tripping is genuinely exercised; the
/// rollback test injects a save-throwing double.
///
/// File-scoped (not nested) to stay within SwiftLint's 1-level nesting.
@MainActor
struct ExchangeCreationHarness {
  let accountStore: AccountStore
  let tokenStore: any ExchangeTokenStoring
  let syncStore: SyncedAccountStore?
  /// The real device-local store, when used, so the suite can clear
  /// keychain rows after each test.
  private let realTokenStore: ExchangeTokenStore?

  init(failingTokenStore: Bool = false) throws {
    let (backend, _) = try TestBackend.create()
    accountStore = AccountStore(
      repository: backend.accounts,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)
    if failingTokenStore {
      tokenStore = FailingExchangeTokenStore()
      realTokenStore = nil
    } else {
      let store = ExchangeTokenStore(synchronizable: false)
      tokenStore = store
      realTokenStore = store
    }
    syncStore = nil
  }

  /// Removes only the keychain row for `accountId` (the account row
  /// lives in the in-memory backend and is torn down with it).
  func cleanUpKeychain(for accountId: UUID) {
    realTokenStore?.delete(for: accountId)
  }
}

/// Save-throwing token-store double — proves the rollback path deletes
/// the just-created account so no "missing token" orphan is left.
struct FailingExchangeTokenStore: ExchangeTokenStoring {
  func save(token: String, for accountId: UUID) throws {
    throw FailingExchangeTokenStoreError.saveFailed
  }

  func token(for accountId: UUID) throws -> String? { nil }

  func delete(for accountId: UUID) {}
}

enum FailingExchangeTokenStoreError: Error {
  case saveFailed
}
