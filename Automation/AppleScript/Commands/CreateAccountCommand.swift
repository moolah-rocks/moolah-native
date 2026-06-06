#if os(macOS)
  import AppKit
  import Foundation
  import OSLog

  private let logger = Logger(subsystem: "com.moolah.app", category: "CreateAccountCommand")

  /// Handles `create account`. Simple cash/investment accounts need only
  /// `name` + `type`; a `crypto` account also needs `wallet address` + `chain`;
  /// an `exchange` account also needs `provider` + `token`.
  class CreateAccountCommand: AppLevelScriptCommand {
    override func performDefaultImplementation() -> Any? {
      guard let profileName = resolveProfileName() else {
        return fail("Missing profile specifier")
      }
      guard let args = evaluatedArguments,
        let name = args["name"] as? String,
        let typeString = args["type"] as? String
      else {
        return fail("Missing required parameters: name and type")
      }
      guard let accountType = AccountType(rawValue: typeString) else {
        return fail(
          "Invalid account type '\(typeString)'. "
            + "Use: bank, cc, asset, investment, crypto, or exchange")
      }

      switch accountType {
      case .crypto:
        return createCrypto(args: args, name: name, profileName: profileName)
      case .exchange:
        return createExchange(args: args, name: name, profileName: profileName)
      case .bank, .creditCard, .asset, .investment:
        return createSimple(type: accountType, name: name, profileName: profileName)
      }
    }

    private func createSimple(type: AccountType, name: String, profileName: String) -> Any? {
      let result: ScriptableAccount? = runBlockingWithError {
        @MainActor () async throws -> ScriptableAccount in
        let service = try Self.requireService()
        let account = try await service.createAccount(
          profileIdentifier: profileName, name: name, type: type)
        return ScriptableAccount(account: account, profileName: profileName)
      }
      return result
    }

    private func createCrypto(args: [String: Any], name: String, profileName: String) -> Any? {
      guard let walletAddress = args["walletAddress"] as? String, !walletAddress.isEmpty else {
        return fail("A crypto account requires a 'wallet address'")
      }
      guard let chain = args["chain"] as? Int else {
        return fail("A crypto account requires a 'chain' (integer chain id, e.g. 1, 10, 8453)")
      }
      let result: ScriptableAccount? = runBlockingWithError {
        @MainActor () async throws -> ScriptableAccount in
        let service = try Self.requireService()
        let account = try await service.createCryptoAccount(
          profileIdentifier: profileName,
          name: name,
          walletAddress: walletAddress,
          chainId: chain)
        return ScriptableAccount(account: account, profileName: profileName)
      }
      return result
    }

    private func createExchange(args: [String: Any], name: String, profileName: String) -> Any? {
      guard let providerString = args["provider"] as? String,
        let provider = ExchangeProvider(rawValue: providerString)
      else {
        return fail("An exchange account requires a valid 'provider' (coinstash)")
      }
      guard let token = args["token"] as? String, !token.isEmpty else {
        return fail("An exchange account requires a 'token'")
      }
      let result: ScriptableAccount? = runBlockingWithError {
        @MainActor () async throws -> ScriptableAccount in
        let service = try Self.requireService()
        let account = try await service.createExchangeAccount(
          profileIdentifier: profileName,
          name: name,
          provider: provider,
          token: token,
          tokenStore: ExchangeTokenStore(synchronizable: true))
        return ScriptableAccount(account: account, profileName: profileName)
      }
      return result
    }

    @MainActor
    private static func requireService() throws -> AutomationService {
      guard let service = ScriptingContext.automationService else {
        throw AutomationError.operationFailed("Scripting not configured")
      }
      return service
    }

    private func fail(_ message: String) -> Any? {
      scriptErrorNumber = -10000
      scriptErrorString = message
      return nil
    }
  }
#endif
