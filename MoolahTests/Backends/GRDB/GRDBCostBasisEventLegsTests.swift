import Foundation
import GRDB
import Testing

@testable import Moolah

/// Behavioural tests for `GRDBTransactionRepository.fetchCostBasisEventLegs()`:
/// only the legs of transactions touching at least one non-fiat instrument
/// are returned, correctly de-scaled from the `INTEGER` Decimal×10^8 storage
/// form and ordered `(date, transaction_id, sort_order)`. The pure-fiat bulk
/// stays in SQLite.
@Suite("fetchCostBasisEventLegs behaviour")
struct GRDBCostBasisEventLegsTests {
  private let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
  private let aud = Instrument.fiat(code: "AUD")

  private func day(_ n: Int) -> Date {
    Date(timeIntervalSince1970: 1_700_000_000 + Double(n) * 86_400)
  }

  /// Builds an in-memory repository with ETH registered in the shared
  /// registry (so it resolves to `.cryptoToken`) and AUD ambient.
  private func makeRepository() async throws -> GRDBTransactionRepository {
    let perProfile = try ProfileDatabase.openInMemory()
    let sharedQueue = try ProfileIndexDatabase.openInMemory()
    let registry = GRDBInstrumentRegistryRepository(database: sharedQueue)
    try await registry.registerCrypto(
      eth,
      mapping: CryptoProviderMapping(
        instrumentId: eth.id, coingeckoId: "ethereum", binanceSymbol: "ETHUSDT"))
    return GRDBTransactionRepository(
      database: perProfile,
      defaultInstrument: aud,
      conversionService: FakeConversionService.fixedRates([:]),
      instrumentResolver: registry,
      instrumentRegistrar: registry)
  }

  @Test
  func returnsOnlyNonFiatTouchingLegs_scaledAndOrdered() async throws {
    let repo = try await makeRepository()
    let account = UUID()

    let fiatOnlyIncome = Transaction(
      date: day(0), payee: "salary",
      legs: [TransactionLeg(accountId: account, instrument: aud, quantity: 5_000, type: .income)])
    let audToEthTrade = Transaction(
      date: day(1), payee: "buy eth",
      legs: [
        TransactionLeg(accountId: account, instrument: aud, quantity: -2_000, type: .trade),
        TransactionLeg(accountId: account, instrument: eth, quantity: 1, type: .trade),
      ])
    let ethReceive = Transaction(
      date: day(2), payee: "airdrop",
      legs: [TransactionLeg(accountId: account, instrument: eth, quantity: 1, type: .income)])

    _ = try await repo.create(fiatOnlyIncome)
    _ = try await repo.create(audToEthTrade)
    _ = try await repo.create(ethReceive)

    let rows = try await repo.fetchCostBasisEventLegs()

    // The pure-fiat transaction's legs never leave SQLite.
    #expect(!rows.contains { $0.transactionId == fiatOnlyIncome.id })
    // Both legs of the trade (the fiat side too) are returned because the
    // transaction touches a non-fiat instrument.
    #expect(rows.filter { $0.transactionId == audToEthTrade.id }.count == 2)
    #expect(rows.contains { $0.transactionId == ethReceive.id })

    // The ETH quantity survives the Int64 ×10^8 round-trip.
    let ethLeg = try #require(rows.first { $0.instrument == eth && $0.type == .trade })
    #expect(ethLeg.quantity == 1)
    #expect(ethLeg.instrument.kind == .cryptoToken)

    // Ordered by (date, transaction_id, sort_order).
    #expect(
      rows
        == rows.sorted {
          ($0.date, $0.transactionId.uuidString, $0.sortOrder)
            < ($1.date, $1.transactionId.uuidString, $1.sortOrder)
        })
  }

  @Test
  func fiatOnlyProfile_returnsNoLegs() async throws {
    let repo = try await makeRepository()
    let account = UUID()
    _ = try await repo.create(
      Transaction(
        date: day(0), payee: "salary",
        legs: [TransactionLeg(accountId: account, instrument: aud, quantity: 5_000, type: .income)])
    )

    let rows = try await repo.fetchCostBasisEventLegs()
    #expect(rows.isEmpty)
  }
}
