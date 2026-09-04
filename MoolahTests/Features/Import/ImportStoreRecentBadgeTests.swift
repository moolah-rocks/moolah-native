import Foundation
import Testing

@testable import Moolah

@Suite("ImportStore recent badge")
@MainActor
struct ImportStoreRecentBadgeTests {
  private func makeStore(backend: any BackendProvider) throws -> (ImportStore, URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("import-store-badge-\(UUID().uuidString)", isDirectory: true)
    let staging = try ImportStagingStore(directory: directory)
    return (
      ImportStore(
        backend: backend,
        staging: staging,
        transferDetection: TransferDetectionCoordinator(
          transactions: backend.transactions,
          suggestions: backend.transferSuggestions)),
      directory
    )
  }

  @Test("badge finds an older-dated import beyond the first 500 transaction dates")
  func badgeIsNotCappedByTransactionDatePaging() async throws {
    let (backend, _) = try TestBackend.create()
    let (store, directory) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let sessionId = UUID()

    var transactions = (0..<500).map { offset in
      Transaction(
        date: now.addingTimeInterval(TimeInterval(offset)),
        payee: "Transfer \(offset)",
        legs: [
          TransactionLeg(
            accountId: nil,
            instrument: .AUD,
            quantity: -1,
            type: .transfer)
        ],
        importOrigin: .single(
          ImportOrigin(
            rawDescription: "Transfer \(offset)",
            rawAmount: -1,
            importedAt: now,
            importSessionId: sessionId,
            parserIdentifier: "test")))
    }
    transactions.append(
      Transaction(
        date: now.addingTimeInterval(-31_536_000),
        payee: "Old purchase imported today",
        legs: [
          TransactionLeg(
            accountId: nil,
            instrument: .AUD,
            quantity: -10,
            type: .expense)
        ],
        importOrigin: .single(
          ImportOrigin(
            rawDescription: "Old purchase imported today",
            rawAmount: -10,
            importedAt: now,
            importSessionId: sessionId,
            parserIdentifier: "test"))))
    _ = try await backend.transactions.createMany(transactions)

    await store.refreshBadge(now: now)

    #expect(store.unreviewedBadgeCount == 1)
  }

  @Test("badge excludes a transaction whose registered instrument is spam")
  func badgeLoadsSpamClassificationFromRegistry() async throws {
    let (backend, _) = try TestBackend.create()
    let (store, directory) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let spam = Instrument.crypto(
      chainId: 1,
      contractAddress: "0x0000000000000000000000000000000000000003",
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
    _ = try await backend.transactions.create(
      Transaction(
        date: now,
        legs: [
          TransactionLeg(
            accountId: nil,
            instrument: spam,
            quantity: -1,
            type: .expense)
        ],
        importOrigin: .single(
          ImportOrigin(
            rawDescription: "Spam",
            rawAmount: -1,
            importedAt: now,
            importSessionId: UUID(),
            parserIdentifier: "wallet"))))

    await store.refreshBadge(now: now)

    #expect(store.unreviewedBadgeCount == 0)
  }
}
