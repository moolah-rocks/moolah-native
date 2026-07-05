// MoolahTests/Shared/CryptoImport/TransferEventBuilderTests.swift
import Foundation
import Testing

@testable import Moolah

/// Behavioural tests for `TransferEventBuilder`. Exercises the
/// transfer-leg construction, hash grouping, sign convention, and the
/// `unknown`-category skip path.
///
/// Gas-leg construction is covered separately in
/// `TransferEventBuilderGasLegTests`; tests here use a
/// `ZeroReceiptAlchemyStub` whose receipts produce a non-positive total
/// (and so emit no gas leg) to keep transfer-leg assertions focused.
@Suite("TransferEventBuilder")
struct TransferEventBuilderTests {
  // Reusable addresses.
  private static let wallet = "0x1111111111111111111111111111111111111111"
  private static let counterparty = "0x2222222222222222222222222222222222222222"
  private static let usdcAddress = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"

  // MARK: - Single ETH send

  @Test("Outbound native ETH → one transfer leg, negative quantity")
  func outboundNativeEthEmitsNegativeTransferLeg() async throws {
    let subject = makeDiscoverySubject()
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
        alchemy: ZeroReceiptAlchemyStub()),
      importOrigin: origin)

    #expect(built.count == 1)
    let candidate = try #require(built.first)
    #expect(candidate.originAccountId == account.id)
    #expect(candidate.transaction.legs.count == 1)
    let leg = try #require(candidate.transaction.legs.first)
    // Outbound external transfer to a non-moolah address: from this
    // account's perspective the wallet paid out (= `.expense`). The
    // cross-account merger promotes paired (.income, .expense) shapes
    // when the counterparty *is* a moolah-tracked account.
    #expect(leg.type == .expense)
    #expect(leg.accountId == account.id)
    #expect(leg.externalId == "0xeth-send:0")
    #expect(leg.instrument == ChainConfig.ethereum.nativeInstrument)
    // 1 ETH outbound → -1
    #expect(leg.quantity == Decimal(-1))
  }

  // MARK: - ERC-20 send

  @Test("Outbound ERC-20 → one transfer leg in the resolved instrument")
  func outboundErc20EmitsTransferLegInResolvedInstrument() async throws {
    let subject = makeDiscoverySubject()
    subject.resolver.script(
      .init(chainId: 1, contractAddress: Self.usdcAddress.lowercased()),
      .success(coingecko: "usd-coin", binance: nil))

    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)
    let origin = makeWalletImportOrigin(for: account.id)
    // 100 USDC (6 decimals) = 100_000_000 raw units.
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
        alchemy: ZeroReceiptAlchemyStub()),
      importOrigin: origin)

    let candidate = try #require(built.first)
    #expect(candidate.transaction.legs.count == 1)
    let leg = try #require(candidate.transaction.legs.first)
    #expect(leg.type == .expense)
    #expect(leg.externalId == "0xerc20-send:0")
    #expect(leg.instrument.kind == .cryptoToken)
    #expect(leg.instrument.contractAddress == Self.usdcAddress.lowercased())
    #expect(leg.instrument.decimals == 6)
    #expect(leg.quantity == Decimal(-100))
  }

  // MARK: - Receive-only

  @Test("Inbound transfer → one transfer leg, positive quantity, no gas")
  func inboundEmitsPositiveTransferLeg() async throws {
    let subject = makeDiscoverySubject()
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
        alchemy: ZeroReceiptAlchemyStub()),
      importOrigin: origin)

    let candidate = try #require(built.first)
    #expect(candidate.transaction.legs.count == 1)
    let leg = try #require(candidate.transaction.legs.first)
    // Inbound from a non-moolah address: the wallet received (= `.income`).
    #expect(leg.type == .income)
    #expect(leg.quantity == Decimal(1))
    #expect(leg.externalId == "0xreceive:0")
  }

  // MARK: - Coincident events on same hash

  @Test("Two ERC-20 transfers same hash → 1 BuiltTransaction with 2 transfer legs")
  func coincidentEventsSameHashYieldOneTransactionTwoLegs() async throws {
    let subject = makeDiscoverySubject()
    subject.resolver.script(
      .init(chainId: 1, contractAddress: Self.usdcAddress.lowercased()),
      .success(coingecko: "usd-coin", binance: nil))

    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)
    let origin = makeWalletImportOrigin(for: account.id)
    let first = makeAlchemyTransfer(
      hash: "0xcomplex",
      from: Self.wallet,
      to: Self.counterparty,
      category: .erc20,
      asset: "USDC",
      contractAddress: Self.usdcAddress,
      decimalsHex: "0x6",
      rawValueHex: "0x5f5e100",
      uniqueIdSuffix: "log:5")
    let second = makeAlchemyTransfer(
      hash: "0xcomplex",
      from: Self.counterparty,
      to: Self.wallet,
      category: .erc20,
      asset: "USDC",
      contractAddress: Self.usdcAddress,
      decimalsHex: "0x6",
      // 25 USDC in raw integer units
      rawValueHex: "0x17d7840",
      uniqueIdSuffix: "log:8")

    let built = try await TransferEventBuilder().build(
      transfers: [first, second],
      account: account,
      services: BuilderServices(
        chain: .ethereum,
        discovery: subject.service,
        alchemy: ZeroReceiptAlchemyStub()),
      importOrigin: origin)

    #expect(built.count == 1)
    let candidate = try #require(built.first)
    #expect(candidate.transaction.legs.count == 2)
    let externalIds = Set(candidate.transaction.legs.compactMap(\.externalId))
    #expect(externalIds == ["0xcomplex:log:5", "0xcomplex:log:8"])
    let signs = candidate.transaction.legs.map { $0.quantity.sign }
    #expect(signs.contains(.minus))
    #expect(signs.contains(.plus))
  }

  // MARK: - NFT category slipped through

  @Test("Unknown-category transfer is skipped and does not crash")
  func unknownCategoryIsSkipped() async throws {
    let subject = makeDiscoverySubject()
    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)
    let origin = makeWalletImportOrigin(for: account.id)
    let json = Data(
      """
      {
        "blockNum": "0x100",
        "uniqueId": "0xnft:0",
        "hash": "0xnft",
        "from": "\(Self.wallet)",
        "to": "\(Self.counterparty)",
        "asset": null,
        "category": "erc721",
        "rawContract": {
          "value": "0x0",
          "address": "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
          "decimal": null
        },
        "metadata": { "blockTimestamp": null }
      }
      """.utf8)
    let nftTransfer = try JSONDecoder().decode(AlchemyTransfer.self, from: json)
    #expect(nftTransfer.category == .unknown)

    let built = try await TransferEventBuilder().build(
      transfers: [nftTransfer],
      account: account,
      services: BuilderServices(
        chain: .ethereum,
        discovery: subject.service,
        alchemy: ZeroReceiptAlchemyStub()),
      importOrigin: origin)
    #expect(built.isEmpty)
  }

  // Token-discovery coalescing across 100 concurrent builders is
  // exercised in `TransferEventBuilderConcurrencyTests`.

  // MARK: - Other edge cases

  @Test("Internal-category transfer is treated as native gas-token movement")
  func internalCategoryUsesNativeInstrument() async throws {
    let subject = makeDiscoverySubject()
    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)
    let origin = makeWalletImportOrigin(for: account.id)
    let transfer = makeAlchemyTransfer(
      hash: "0xinternal",
      from: Self.counterparty,
      to: Self.wallet,
      category: .internal,
      asset: "ETH",
      decimalsHex: nil,
      rawValueHex: "0x0de0b6b3a7640000")

    let built = try await TransferEventBuilder().build(
      transfers: [transfer],
      account: account,
      services: BuilderServices(
        chain: .ethereum,
        discovery: subject.service,
        alchemy: ZeroReceiptAlchemyStub()),
      importOrigin: origin)
    let leg = try #require(built.first?.transaction.legs.first)
    #expect(leg.instrument == ChainConfig.ethereum.nativeInstrument)
    #expect(leg.quantity == Decimal(1))
  }

  @Test("Missing wallet address on account throws providerMalformedResponse")
  func missingWalletAddressThrows() async throws {
    let subject = makeDiscoverySubject()
    var account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)
    account.walletAddress = nil
    let origin = makeWalletImportOrigin(for: account.id)

    await #expect(throws: WalletSyncError.self) {
      _ = try await TransferEventBuilder().build(
        transfers: [],
        account: account,
        services: BuilderServices(
          chain: .ethereum,
          discovery: subject.service,
          alchemy: ZeroReceiptAlchemyStub()),
        importOrigin: origin)
    }
  }
}
