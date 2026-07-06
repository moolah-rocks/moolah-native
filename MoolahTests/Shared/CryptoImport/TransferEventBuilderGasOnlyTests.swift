// MoolahTests/Shared/CryptoImport/TransferEventBuilderGasOnlyTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("TransferEventBuilder — gas-only signed txs (#919)")
struct TransferEventBuilderGasOnlyTests {
  private let wallet = "0xa4b572ea1b6f734fc88a0a004c5301f8dad54d60"

  @Test
  func gasOnlyHashWithNoTransfersEmitsGasLegOnlyTransaction() async throws {
    let account = makeCryptoAccount(walletAddress: wallet, chain: .ethereum)
    let origin = makeWalletImportOrigin(for: account.id)
    let alchemy = RecordingAlchemyClientStub()
    let hash = "0xAPPROVE"
    alchemy.setReceiptResponse(
      .receipt(
        AlchemyTransactionReceipt(
          hash: hash,
          gasUsed: Decimal(21_000),
          effectiveGasPrice: Decimal(1_000_000_000),
          from: wallet)),
      for: hash)
    let services = BuilderServices(
      chain: .ethereum,
      discovery: makeDiscoverySubject().service,
      alchemy: alchemy)
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

    let built = try await TransferEventBuilder().build(
      transfers: [],
      account: account,
      services: services,
      importOrigin: origin,
      signedGasTxs: [SignedGasTx(hash: hash, blockTimestamp: timestamp, blockNumber: 100)])

    // 21_000 gas × 1_000_000_000 wei/gas = 21_000_000_000_000 wei = 0.000021 ETH (negative: expense)
    let expectedGas =
      Decimal(-21_000_000_000_000) / Decimal(sign: .plus, exponent: 18, significand: 1)
    #expect(built.count == 1)
    let legs = try #require(built.first?.transaction.legs)
    #expect(legs.count == 1)
    #expect(legs.first?.externalId == "\(hash):gas")
    #expect(legs.first?.type == .expense)
    #expect(legs.first?.quantity == expectedGas)
    #expect(built.first?.transaction.date == timestamp)
  }

  @Test
  func hashWithTransfersDoesNotGetDuplicateGasLeg() async throws {
    // A normal outbound ETH send: one transfer leg + exactly one gas leg.
    let account = makeCryptoAccount(walletAddress: wallet, chain: .ethereum)
    let origin = makeWalletImportOrigin(for: account.id)
    let alchemy = RecordingAlchemyClientStub()
    let hash = "0xSEND"
    alchemy.setReceiptResponse(
      .receipt(
        AlchemyTransactionReceipt(
          hash: hash,
          gasUsed: Decimal(21_000),
          effectiveGasPrice: Decimal(1_000_000_000),
          from: wallet)),
      for: hash)
    let services = BuilderServices(
      chain: .ethereum,
      discovery: makeDiscoverySubject().service,
      alchemy: alchemy)
    let transfer = AlchemyTransfer(
      hash: hash, uniqueId: "\(hash):external:0",
      from: wallet, to: "0xDEF", category: .external, asset: nil,
      rawContract: .init(address: nil, decimal: nil, rawValue: "0xde0b6b3a7640000"),
      metadata: .init(blockTimestamp: "2024-09-12T12:34:56.000000Z"),
      blockNum: "0x64")

    let built = try await TransferEventBuilder().build(
      transfers: [transfer],
      account: account,
      services: services,
      importOrigin: origin,
      signedGasTxs: [SignedGasTx(hash: hash, blockTimestamp: Date(), blockNumber: 100)])

    #expect(built.count == 1)
    let legs = try #require(built.first?.transaction.legs)
    #expect(legs.filter { $0.externalId == "\(hash):gas" }.count == 1)
    #expect(legs.contains { $0.externalId == "\(hash):external:0" })
  }

  @Test
  func gasOnlyHashWhoseReceiptFailsProducesNoTransactionAndDoesNotThrow() async throws {
    let account = makeCryptoAccount(walletAddress: wallet, chain: .ethereum)
    let origin = makeWalletImportOrigin(for: account.id)
    let alchemy = RecordingAlchemyClientStub()
    let hash = "0xBAD"
    alchemy.setReceiptResponse(
      .failure(WalletSyncError.network(underlyingDescription: "x")), for: hash)
    let services = BuilderServices(
      chain: .ethereum,
      discovery: makeDiscoverySubject().service,
      alchemy: alchemy)

    let built = try await TransferEventBuilder().build(
      transfers: [],
      account: account,
      services: services,
      importOrigin: origin,
      signedGasTxs: [SignedGasTx(hash: hash, blockTimestamp: Date(), blockNumber: 100)])

    #expect(built.isEmpty)
  }
}
