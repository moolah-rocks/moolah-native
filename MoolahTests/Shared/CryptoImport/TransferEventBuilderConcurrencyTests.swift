// MoolahTests/Shared/CryptoImport/TransferEventBuilderConcurrencyTests.swift
import Foundation
import Testing

@testable import Moolah

/// Concurrency-focused coverage for the parallel paths inside
/// `TransferEventBuilder`: the token-discovery coalescer (verified by
/// the 100-concurrent-builders test). The receipt-coalescing path lives
/// in `TransferEventBuilderGasCoalescingTests`.
@Suite("TransferEventBuilder — concurrency")
struct TransferEventBuilderConcurrencyTests {
  private static let wallet = "0x1111111111111111111111111111111111111111"
  private static let counterparty = "0x2222222222222222222222222222222222222222"
  private static let usdcAddress = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"

  @Test("100 concurrent builders → single resolver call (coalescer holds)")
  func concurrentBuildersCoalesceInstrumentResolution() async throws {
    let subject = makeDiscoverySubject()
    subject.resolver.script(
      .init(chainId: 1, contractAddress: Self.usdcAddress.lowercased()),
      .success(coingecko: "usd-coin", binance: nil))

    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)
    let origin = makeWalletImportOrigin(for: account.id)
    let template = makeAlchemyTransfer(
      hash: "0xshared",
      from: Self.wallet,
      to: Self.counterparty,
      category: .erc20,
      asset: "USDC",
      contractAddress: Self.usdcAddress,
      decimalsHex: "0x6",
      rawValueHex: "0x5f5e100")

    // Each task uses a unique hash so the builder doesn't collapse into
    // a single transaction; the discovery key is the same so the
    // coalescer is the load-bearing claim.
    try await withThrowingTaskGroup(of: Set<String>.self) { group in
      for index in 0..<100 {
        let hash = "0x\(String(format: "%064x", index))"
        let transfer = makeAlchemyTransfer(
          hash: hash,
          from: template.from,
          to: template.to,
          category: .erc20,
          asset: "USDC",
          contractAddress: Self.usdcAddress,
          decimalsHex: "0x6",
          rawValueHex: "0x5f5e100")
        group.addTask {
          let built = try await TransferEventBuilder().build(
            transfers: [transfer],
            account: account,
            services: BuilderServices(
              chain: .ethereum,
              discovery: subject.service,
              alchemy: ZeroReceiptAlchemyStub()),
            importOrigin: origin)
          return Set(built.flatMap { $0.transaction.legs.map(\.instrument.id) })
        }
      }
      var observed: Set<String> = []
      for try await ids in group {
        observed.formUnion(ids)
      }
      #expect(observed.count == 1)
    }

    let resolverKey = CountingRegistrationResolver.Key(
      chainId: 1, contractAddress: Self.usdcAddress.lowercased())
    #expect(subject.resolver.callCount(for: resolverKey) == 1)
  }
}
