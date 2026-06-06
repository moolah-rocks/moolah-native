import Foundation
import Testing

@testable import Moolah

/// Covers `AutomationService.createCryptoAccount(...)` and
/// `createExchangeAccount(...)` — the scripted equivalents of the crypto /
/// exchange branches of the create-account sheet. The methods reuse the
/// production `CryptoAccountCreationLogic` / `ExchangeAccountCreationLogic`
/// but pass a `nil` sync store: a script kicks off sync explicitly with the
/// `synchronize` command, so creation stays network-free and deterministic.
@Suite("AutomationService Synced Account Creation")
@MainActor
struct AutomationServiceSyncedAccountTests {
  /// A valid lowercase EVM wallet address for crypto-account assertions.
  private let walletAddress = "0xa1eaee65e5fb8f05cca1cc2b9126550e23513511"

  @Test("createCryptoAccount creates a .crypto account with wallet + chain")
  func createCryptoAccount() async throws {
    let (service, _) = try await AutomationTestSession.make()

    let account = try await service.createCryptoAccount(
      profileIdentifier: "Test",
      name: "Trust - Ethereum",
      walletAddress: walletAddress,
      chainId: 1)

    #expect(account.name == "Trust - Ethereum")
    #expect(account.type == .crypto)
    #expect(account.walletAddress == walletAddress)
    #expect(account.chainId == 1)
    #expect(account.valuationMode == .calculatedFromTrades)
  }

  @Test("createCryptoAccount rejects an unsupported chain id")
  func createCryptoAccountUnsupportedChain() async throws {
    let (service, _) = try await AutomationTestSession.make()

    await #expect(throws: AutomationError.self) {
      _ = try await service.createCryptoAccount(
        profileIdentifier: "Test",
        name: "Bad Chain",
        walletAddress: walletAddress,
        chainId: 999_999)
    }
  }

  @Test("createCryptoAccount rejects an invalid wallet address")
  func createCryptoAccountInvalidAddress() async throws {
    let (service, _) = try await AutomationTestSession.make()

    await #expect(throws: AutomationError.self) {
      _ = try await service.createCryptoAccount(
        profileIdentifier: "Test",
        name: "Bad Address",
        walletAddress: "not-an-address",
        chainId: 1)
    }
  }

  @Test("createExchangeAccount creates a .exchange account and stores its token")
  func createExchangeAccount() async throws {
    let (service, _) = try await AutomationTestSession.make()
    // Device-local keychain (no entitlement) so the token round-trip runs
    // in the test host; cleaned up after the assertions.
    let tokenStore = ExchangeTokenStore(synchronizable: false)

    let account = try await service.createExchangeAccount(
      profileIdentifier: "Test",
      name: "Coinstash",
      provider: .coinstash,
      token: "TOK123",
      tokenStore: tokenStore)

    #expect(account.name == "Coinstash")
    #expect(account.type == .exchange)
    #expect(account.exchangeProvider == .coinstash)
    #expect(account.valuationMode == .calculatedFromTrades)
    #expect(try tokenStore.token(for: account.id) == "TOK123")

    tokenStore.delete(for: account.id)
  }

  @Test("createExchangeAccount rolls back the account when the token save fails")
  func createExchangeAccountRollsBackOnTokenFailure() async throws {
    let (service, _) = try await AutomationTestSession.make()

    await #expect(throws: AutomationError.self) {
      _ = try await service.createExchangeAccount(
        profileIdentifier: "Test",
        name: "Coinstash",
        provider: .coinstash,
        token: "TOK",
        tokenStore: FailingExchangeTokenStore())
    }

    // `AccountStore.delete(id:)` is the codebase-wide soft-delete (flips
    // `isHidden`), so the rolled-back row remains in `fetchAll()` but is
    // hidden: assert no *visible* exchange account is left behind.
    let accounts = try await service.fetchAccounts(profileIdentifier: "Test")
    #expect(!accounts.contains { $0.type == .exchange && !$0.isHidden })
  }
}
