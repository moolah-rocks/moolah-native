import Foundation
import Testing

@testable import Moolah

/// Shared fixtures for the AutomationService leg-editing suites.
@MainActor
enum LegTestSupport {

  /// Persists a single-leg transaction directly through the repository so the
  /// leg's `externalId` can be set (the create-transaction service surface
  /// does not expose it). The leg sits in the profile's instrument; its
  /// `.income` / `.expense` type follows the quantity's sign.
  static func makeSingleLeg(
    session: ProfileSession,
    accountId: UUID,
    quantity: Decimal,
    payee: String,
    externalId: String? = nil
  ) async throws -> Transaction {
    let transaction = Transaction(
      id: UUID(),
      date: Date(),
      payee: payee,
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: session.profile.instrument,
          quantity: quantity,
          externalId: externalId,
          type: quantity < 0 ? .expense : .income)
      ])
    return try await session.backend.transactions.create(transaction)
  }

  /// Authoritative by-id read from the repository snapshot.
  static func fetchById(_ session: ProfileSession, _ id: UUID) async throws -> Transaction {
    let all = try await session.backend.transactions.fetchAll(filter: TransactionFilter())
    return try #require(all.first { $0.id == id })
  }

  /// Registers a USDC crypto instrument in the profile's registry and returns it,
  /// so a leg can resolve an explicit crypto instrument id.
  static func registerUSDC(session: ProfileSession) async throws -> Instrument {
    let registry = try #require(session.instrumentRegistry)
    let usdc = Instrument.crypto(
      chainId: 1,
      contractAddress: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      symbol: "USDC",
      name: "USD Coin",
      decimals: 6)
    try await registry.registerCrypto(
      usdc,
      mapping: CryptoProviderMapping(
        instrumentId: usdc.id,
        coingeckoId: "usd-coin",
        binanceSymbol: nil))
    return usdc
  }
}
