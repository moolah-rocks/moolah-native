// MoolahTests/Shared/CryptoImport/TransferEventBuilderGasCoalescingTests.swift
import Foundation
import Testing

@testable import Moolah

/// Coalescing-specific coverage for the gas-leg receipt fetches.
/// Verifies the per-hash deduplication that keeps an N-leg outbound
/// transaction to a single `eth_getTransactionReceipt` round-trip.
@Suite("TransferEventBuilder — gas leg coalescing")
struct TransferEventBuilderGasCoalescingTests {
  private static let wallet = "0x1111111111111111111111111111111111111111"
  private static let counterparty = "0x2222222222222222222222222222222222222222"
  private static let usdcAddress = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"

  private static let gasUsed = Decimal(21_000)
  private static let gasPrice = Decimal(1_500_000_000)

  @Test("1 outbound + 4 inbound across distinct hashes → exactly 1 receipt fetch")
  func oneOutboundFourInboundCoalescesToSingleReceipt() async throws {
    let subject = makeDiscoverySubject()
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setReceiptResponse(
      .receipt(
        AlchemyTransactionReceipt(
          hash: "0xout",
          gasUsed: Self.gasUsed,
          effectiveGasPrice: Self.gasPrice,
          from: Self.wallet)
      ),
      for: "0xout")

    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)
    let origin = makeWalletImportOrigin(for: account.id)
    var transfers: [AlchemyTransfer] = [
      makeAlchemyTransfer(
        hash: "0xout", from: Self.wallet, to: Self.counterparty,
        category: .external)
    ]
    for index in 0..<4 {
      transfers.append(
        makeAlchemyTransfer(
          hash: "0xin\(index)",
          from: Self.counterparty,
          to: Self.wallet,
          category: .external))
    }

    _ = try await TransferEventBuilder().build(
      transfers: transfers,
      account: account,
      services: BuilderServices(
        chain: .ethereum,
        discovery: subject.service,
        alchemy: alchemy),
      importOrigin: origin)

    #expect(alchemy.recordedReceiptCalls == ["0xout"])
  }

  @Test("5 outbound across 5 distinct hashes → 5 receipt fetches")
  func fiveOutboundDistinctHashesFetchFiveReceipts() async throws {
    let subject = makeDiscoverySubject()
    let alchemy = RecordingAlchemyClientStub()
    for index in 0..<5 {
      alchemy.setReceiptResponse(
        .receipt(
          AlchemyTransactionReceipt(
            hash: "0xout\(index)",
            gasUsed: Self.gasUsed,
            effectiveGasPrice: Self.gasPrice,
            from: Self.wallet)
        ),
        for: "0xout\(index)")
    }

    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)
    let origin = makeWalletImportOrigin(for: account.id)
    var transfers: [AlchemyTransfer] = []
    for index in 0..<5 {
      transfers.append(
        makeAlchemyTransfer(
          hash: "0xout\(index)",
          from: Self.wallet,
          to: Self.counterparty,
          category: .external))
    }

    _ = try await TransferEventBuilder().build(
      transfers: transfers,
      account: account,
      services: BuilderServices(
        chain: .ethereum,
        discovery: subject.service,
        alchemy: alchemy),
      importOrigin: origin)

    #expect(Set(alchemy.recordedReceiptCalls).count == 5)
    #expect(alchemy.recordedReceiptCalls.count == 5)
  }

  @Test("Two outbound legs sharing one hash → exactly 1 receipt fetch")
  func twoOutboundLegsSameHashFetchOnce() async throws {
    let subject = makeDiscoverySubject()
    subject.resolver.script(
      .init(chainId: 1, contractAddress: Self.usdcAddress.lowercased()),
      .success(coingecko: "usd-coin", binance: nil))
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setReceiptResponse(
      .receipt(
        AlchemyTransactionReceipt(
          hash: "0xmulti",
          gasUsed: Self.gasUsed,
          effectiveGasPrice: Self.gasPrice,
          from: Self.wallet)
      ),
      for: "0xmulti")

    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)
    let origin = makeWalletImportOrigin(for: account.id)
    let nativeLeg = makeAlchemyTransfer(
      hash: "0xmulti",
      from: Self.wallet,
      to: Self.counterparty,
      category: .external)
    let erc20Leg = makeAlchemyTransfer(
      hash: "0xmulti",
      from: Self.wallet,
      to: Self.counterparty,
      category: .erc20,
      asset: "USDC",
      contractAddress: Self.usdcAddress,
      decimalsHex: "0x6",
      rawValueHex: "0x5f5e100")

    let built = try await TransferEventBuilder().build(
      transfers: [nativeLeg, erc20Leg],
      account: account,
      services: BuilderServices(
        chain: .ethereum,
        discovery: subject.service,
        alchemy: alchemy),
      importOrigin: origin)

    #expect(alchemy.recordedReceiptCalls == ["0xmulti"])
    let candidate = try #require(built.first)
    // Filter by the gas leg's `:gas` `externalId` suffix; outbound value
    // legs are `.expense` too, so type alone does not disambiguate.
    let gasLegs = candidate.transaction.legs.filter {
      $0.externalId?.hasSuffix(":gas") == true
    }
    #expect(gasLegs.count == 1)
  }
}
