import Foundation
import Testing

@testable import Moolah

@Suite("InsightInputBuilder spam review count")
struct InsightInputBuilderSpamTests {
  @Test("registered spam transaction is excluded from the category backlog")
  func excludesRegisteredSpam() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let spam = Instrument.crypto(
      chainId: 1,
      contractAddress: "0x0000000000000000000000000000000000000004",
      symbol: "SPAM",
      name: "Spam",
      decimals: 18)
    try await backend.instrumentRegistryRepository.registerCrypto(
      spam,
      mapping: CryptoProviderMapping(
        instrumentId: spam.id,
        coingeckoId: "spam-token",
        binanceSymbol: nil),
      forcingStatus: .spam)
    let now = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 15)
    _ = try await backend.transactions.create(
      Transaction(
        date: now,
        legs: [
          TransactionLeg(
            accountId: nil,
            instrument: spam,
            quantity: -1,
            type: .expense)
        ]))

    let input = try await InsightInputBuilder(backend: backend).build(
      snapshot: InsightInputSnapshot(),
      context: InsightContext(now: now, reportingCurrency: .AUD))

    #expect(input.uncategorizedTransactionCount == 0)
  }
}
