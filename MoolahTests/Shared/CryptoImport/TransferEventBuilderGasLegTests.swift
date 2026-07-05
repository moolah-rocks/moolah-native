// MoolahTests/Shared/CryptoImport/TransferEventBuilderGasLegTests.swift
import Foundation
import Testing

@testable import Moolah

/// Behavioural coverage for the gas-leg construction.
/// Lives in its own suite because the receipt-fetch coalescing is a
/// distinct concern from transfer-leg construction (covered by
/// `TransferEventBuilderTests`). All tests here use
/// `RecordingAlchemyClientStub.setReceiptResponse(_:for:)` to script
/// per-hash receipts so the coalescing assertions stay precise.
@Suite("TransferEventBuilder — gas leg")
struct TransferEventBuilderGasLegTests {
  private static let wallet = "0x1111111111111111111111111111111111111111"
  private static let counterparty = "0x2222222222222222222222222222222222222222"
  private static let usdcAddress = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"

  // 21_000 gas * 1.5 gwei = 31_500_000_000_000 wei = 0.0000315 ETH.
  private static let gasUsed = Decimal(21_000)
  private static let gasPrice = Decimal(1_500_000_000)
  private static let expectedFeeEth = dec("0.0000315")

  // MARK: - Native send + gas leg

  @Test("Outbound native ETH + receipt → 2 legs (transfer + gas), same externalId")
  func outboundNativeSendAttachesGasLeg() async throws {
    let subject = makeDiscoverySubject()
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setReceiptResponse(
      .receipt(
        AlchemyTransactionReceipt(
          hash: "0xeth-send",
          gasUsed: Self.gasUsed,
          effectiveGasPrice: Self.gasPrice,
          from: Self.wallet)
      ),
      for: "0xeth-send")

    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)
    let origin = makeWalletImportOrigin(for: account.id)
    let transfer = makeAlchemyTransfer(
      hash: "0xeth-send",
      from: Self.wallet,
      to: Self.counterparty,
      category: .external)

    let built = try await TransferEventBuilder().build(
      transfers: [transfer],
      account: account,
      services: BuilderServices(
        chain: .ethereum,
        discovery: subject.service,
        alchemy: alchemy),
      importOrigin: origin)

    let candidate = try #require(built.first)
    #expect(candidate.transaction.legs.count == 2)
    // Outbound + gas: both legs are `.expense` per the wallet
    // importer's per-account types — disambiguate by the gas leg's
    // `:gas` `externalId` suffix.
    let transferLeg = try #require(
      candidate.transaction.legs.first(where: { $0.externalId == "0xeth-send:0" }))
    let gasLeg = try #require(
      candidate.transaction.legs.first(where: { $0.externalId == "0xeth-send:gas" }))
    #expect(transferLeg.type == .expense)
    #expect(gasLeg.type == .expense)
    #expect(gasLeg.instrument == ChainConfig.ethereum.nativeInstrument)
    #expect(gasLeg.quantity == -Self.expectedFeeEth)
    #expect(gasLeg.accountId == account.id)
  }

  @Test("Outbound ERC-20 + receipt → 2 legs (token transfer + native gas)")
  func outboundErc20AttachesGasLegInNativeInstrument() async throws {
    let subject = makeDiscoverySubject()
    subject.resolver.script(
      .init(chainId: 1, contractAddress: Self.usdcAddress.lowercased()),
      .success(coingecko: "usd-coin", binance: nil))
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setReceiptResponse(
      .receipt(
        AlchemyTransactionReceipt(
          hash: "0xerc20-send",
          gasUsed: Self.gasUsed,
          effectiveGasPrice: Self.gasPrice,
          from: Self.wallet)
      ),
      for: "0xerc20-send")

    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)
    let origin = makeWalletImportOrigin(for: account.id)
    let transfer = makeAlchemyTransfer(
      hash: "0xerc20-send",
      from: Self.wallet,
      to: Self.counterparty,
      category: .erc20,
      asset: "USDC",
      contractAddress: Self.usdcAddress,
      decimalsHex: "0x6",
      rawValueHex: "0x5f5e100")

    let built = try await TransferEventBuilder().build(
      transfers: [transfer],
      account: account,
      services: BuilderServices(
        chain: .ethereum,
        discovery: subject.service,
        alchemy: alchemy),
      importOrigin: origin)

    let candidate = try #require(built.first)
    #expect(candidate.transaction.legs.count == 2)
    let transferLeg = try #require(
      candidate.transaction.legs.first(where: { $0.externalId == "0xerc20-send:0" }))
    let gasLeg = try #require(
      candidate.transaction.legs.first(where: { $0.externalId == "0xerc20-send:gas" }))
    #expect(transferLeg.type == .expense)
    #expect(gasLeg.type == .expense)
    #expect(transferLeg.instrument.contractAddress == Self.usdcAddress.lowercased())
    #expect(gasLeg.instrument == ChainConfig.ethereum.nativeInstrument)
    #expect(gasLeg.quantity == -Self.expectedFeeEth)
  }

  // MARK: - Inbound never gets a gas leg

  @Test("Inbound transfer → no gas leg, no receipt fetch")
  func inboundTransferDoesNotFetchReceipt() async throws {
    let subject = makeDiscoverySubject()
    let alchemy = RecordingAlchemyClientStub()
    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)
    let origin = makeWalletImportOrigin(for: account.id)
    let transfer = makeAlchemyTransfer(
      hash: "0xreceive",
      from: Self.counterparty,
      to: Self.wallet,
      category: .external)

    let built = try await TransferEventBuilder().build(
      transfers: [transfer],
      account: account,
      services: BuilderServices(
        chain: .ethereum,
        discovery: subject.service,
        alchemy: alchemy),
      importOrigin: origin)

    let candidate = try #require(built.first)
    #expect(candidate.transaction.legs.count == 1)
    // Inbound from a non-moolah address: the leg is `.income`, not
    // `.transfer` — `.transfer` is reserved for cross-account pairs.
    #expect(candidate.transaction.legs.allSatisfy { $0.type == .income })
    #expect(alchemy.recordedReceiptCalls.isEmpty)
  }

  // MARK: - Self-send still pays gas

  @Test("Self-send → income leg + gas leg (gas is paid even on self-send)")
  func selfSendStillProducesGasLeg() async throws {
    let subject = makeDiscoverySubject()
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setReceiptResponse(
      .receipt(
        AlchemyTransactionReceipt(
          hash: "0xself",
          gasUsed: Self.gasUsed,
          effectiveGasPrice: Self.gasPrice,
          from: Self.wallet)
      ),
      for: "0xself")

    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)
    let origin = makeWalletImportOrigin(for: account.id)
    let transfer = makeAlchemyTransfer(
      hash: "0xself",
      from: Self.wallet,
      to: Self.wallet,
      category: .external)

    let built = try await TransferEventBuilder().build(
      transfers: [transfer],
      account: account,
      services: BuilderServices(
        chain: .ethereum,
        discovery: subject.service,
        alchemy: alchemy),
      importOrigin: origin)

    let candidate = try #require(built.first)
    let types = candidate.transaction.legs.map(\.type)
    // Self-send: value leg is typed `.income` (positive quantity), gas
    // leg is `.expense`.
    #expect(types.filter { $0 == .income }.count == 1)
    #expect(types.filter { $0 == .expense }.count == 1)
  }

  // MARK: - Receipt fetch failure on one hash doesn't fail the account

  @Test("Receipt fetch failure on one hash → other events still build")
  func receiptFetchFailureOnOneHashDoesNotPropagate() async throws {
    let subject = makeDiscoverySubject()
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setReceiptResponse(
      .receipt(
        AlchemyTransactionReceipt(
          hash: "0xgood",
          gasUsed: Self.gasUsed,
          effectiveGasPrice: Self.gasPrice,
          from: Self.wallet)
      ),
      for: "0xgood")
    alchemy.setReceiptResponse(
      .failure(WalletSyncError.network(underlyingDescription: "transient")),
      for: "0xbad")

    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)
    let origin = makeWalletImportOrigin(for: account.id)
    let goodTransfer = makeAlchemyTransfer(
      hash: "0xgood", from: Self.wallet, to: Self.counterparty,
      category: .external)
    let badTransfer = makeAlchemyTransfer(
      hash: "0xbad", from: Self.wallet, to: Self.counterparty,
      category: .external)

    let built = try await TransferEventBuilder().build(
      transfers: [goodTransfer, badTransfer],
      account: account,
      services: BuilderServices(
        chain: .ethereum,
        discovery: subject.service,
        alchemy: alchemy),
      importOrigin: origin)

    #expect(built.count == 2)
    let goodCandidate = try #require(
      built.first { candidate in
        candidate.transaction.legs.contains { $0.externalId == "0xgood:0" }
      })
    let badCandidate = try #require(
      built.first { candidate in
        candidate.transaction.legs.contains { $0.externalId == "0xbad:0" }
      })
    // Good event keeps both legs (value + gas, both `.expense`).
    #expect(goodCandidate.transaction.legs.count == 2)
    #expect(goodCandidate.transaction.legs.allSatisfy { $0.type == .expense })
    // Bad event keeps the value leg but skips gas — receipt failure
    // must not corrupt the account-level result.
    #expect(badCandidate.transaction.legs.count == 1)
    #expect(badCandidate.transaction.legs.allSatisfy { $0.type == .expense })
  }

}
