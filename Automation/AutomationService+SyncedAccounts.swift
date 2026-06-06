import Foundation

// Synced-account creation for `AutomationService`: crypto wallet accounts
// (address + chain) and exchange accounts (provider + API token). Both reuse
// the production creation logic the create-account sheet drives, so a script
// behaves exactly like the UI — including the exchange token-save rollback.
//
// Neither method kicks off the initial sync: a script syncs explicitly with
// the `synchronize` command once the accounts exist, which is deterministic
// (the script can await completion) and keeps creation network-free. Both
// members are `@MainActor` via the containing class.
extension AutomationService {

  /// Creates a crypto wallet account synced from on-chain history.
  ///
  /// `chainId` must be one of the supported chains (`ChainConfig.all`:
  /// 1 Ethereum, 10 OP Mainnet, 8453 Base). `walletAddress` is validated
  /// and normalised by `CryptoAccountCreationLogic`.
  func createCryptoAccount(
    profileIdentifier: String,
    name: String,
    walletAddress: String,
    chainId: Int
  ) async throws -> Account {
    let session = try resolveSession(for: profileIdentifier)
    guard let chain = ChainConfig.config(for: chainId) else {
      let supported = ChainConfig.all.map { String($0.chainId) }.joined(separator: ", ")
      throw AutomationError.operationFailed(
        "Unsupported chain id \(chainId). Supported chain ids: \(supported).")
    }
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      throw AutomationError.operationFailed("Account name must not be empty")
    }
    let logic = CryptoAccountCreationLogic(
      accountStore: session.accountStore,
      cryptoSyncStore: nil,
      accountInstrument: session.profile.instrument)
    switch await logic.submit(name: name, chain: chain, walletAddressInput: walletAddress) {
    case .created(let account):
      return account
    case .invalidAddress:
      throw AutomationError.operationFailed(
        "Invalid wallet address '\(walletAddress)'")
    case .failure(let error):
      throw AutomationError.operationFailed(
        "Failed to create crypto account: \(error.localizedDescription)")
    }
  }

  /// Creates an exchange account synced from a provider's API, storing its
  /// read-only API token in the keychain. On a token-save failure the
  /// just-created account is rolled back (no orphan), surfaced here as a
  /// thrown error.
  ///
  /// The caller supplies the `tokenStore`: production passes the iCloud-
  /// synchronisable keychain store; tests inject a device-local or failing
  /// double.
  func createExchangeAccount(
    profileIdentifier: String,
    name: String,
    provider: ExchangeProvider,
    token: String,
    tokenStore: any ExchangeTokenStoring
  ) async throws -> Account {
    let session = try resolveSession(for: profileIdentifier)
    let logic = ExchangeAccountCreationLogic(
      accountStore: session.accountStore,
      tokenStore: tokenStore,
      syncStore: nil,
      profileInstrument: session.profile.instrument)
    switch await logic.submit(name: name, provider: provider, token: token) {
    case .created(let account):
      return account
    case .invalidInput:
      throw AutomationError.operationFailed("Invalid account name or empty API token")
    case .failure(let error):
      throw AutomationError.operationFailed(
        "Failed to create exchange account: \(error.localizedDescription)")
    }
  }
}
