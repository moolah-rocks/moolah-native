// MoolahTests/Shared/CryptoImport/TransferEventBuilderSwapTests.swift
import Foundation
import Testing

@testable import Moolah

/// Integration tests for `TransferEventBuilder` covering intra-account
/// token-swap detection. Pairs same-hash inbound and outbound transfers
/// for one wallet across distinct instruments and asserts the produced
/// transaction's legs are typed `.trade`, with the gas leg (if any) left
/// as `.expense`.
@Suite("TransferEventBuilder — intra-account swap")
struct TransferEventBuilderSwapTests {
  private static let wallet = "0x1111111111111111111111111111111111111111"
  private static let counterparty = "0x2222222222222222222222222222222222222222"
  private static let usdcAddress = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
  private static let proveAddress = "0xb0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"

  // 21_000 gas * 1.5 gwei = 0.0000315 ETH
  private static let gasUsed = Decimal(21_000)
  private static let gasPrice = Decimal(1_500_000_000)
  private static let expectedGasFeeEth = Decimal(string: "0.0000315") ?? 0

  @Test("ETH out + ERC-20 in (no receipt) → 2 .trade legs, no gas leg, isTrade==true")
  func twoTokenSwapWithoutReceiptProducesTradeLegs() async throws {
    let subject = makeDiscoverySubject()
    subject.resolver.script(
      .init(chainId: 1, contractAddress: Self.usdcAddress.lowercased()),
      .success(coingecko: "usd-coin", binance: nil))

    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)
    let origin = makeWalletImportOrigin(for: account.id)
    // 1 ETH outbound (1 * 10^18 wei).
    let ethOut = makeAlchemyTransfer(
      hash: "0xswap",
      from: Self.wallet,
      to: Self.counterparty,
      category: .external,
      uniqueIdSuffix: "0")
    // 100 USDC inbound (100 * 10^6).
    let usdcIn = makeAlchemyTransfer(
      hash: "0xswap",
      from: Self.counterparty,
      to: Self.wallet,
      category: .erc20,
      asset: "USDC",
      contractAddress: Self.usdcAddress,
      decimalsHex: "0x6",
      rawValueHex: "0x5f5e100",
      uniqueIdSuffix: "1")

    let built = try await TransferEventBuilder().build(
      transfers: [ethOut, usdcIn],
      account: account,
      services: BuilderServices(
        chain: .ethereum,
        discovery: subject.service,
        alchemy: ZeroReceiptAlchemyStub()),
      importOrigin: origin)

    let candidate = try #require(built.first)
    let legs = candidate.transaction.legs
    #expect(legs.count == 2)
    #expect(legs.allSatisfy { $0.type == .trade })
    #expect(candidate.transaction.isTrade)
  }

  @Test("ETH out + ERC-20 in + receipt → 2 .trade + 1 .expense gas, isTrade==true")
  func twoTokenSwapWithReceiptIncludesGasLeg() async throws {
    let subject = makeDiscoverySubject()
    subject.resolver.script(
      .init(chainId: 1, contractAddress: Self.usdcAddress.lowercased()),
      .success(coingecko: "usd-coin", binance: nil))

    let alchemy = RecordingAlchemyClientStub()
    alchemy.setReceiptResponse(
      .receipt(
        AlchemyTransactionReceipt(
          hash: "0xswap",
          gasUsed: Self.gasUsed,
          effectiveGasPrice: Self.gasPrice,
          from: Self.wallet)),
      for: "0xswap")

    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)
    let origin = makeWalletImportOrigin(for: account.id)
    let ethOut = makeAlchemyTransfer(
      hash: "0xswap", from: Self.wallet, to: Self.counterparty,
      category: .external, uniqueIdSuffix: "0")
    let usdcIn = makeAlchemyTransfer(
      hash: "0xswap", from: Self.counterparty, to: Self.wallet,
      category: .erc20, asset: "USDC",
      contractAddress: Self.usdcAddress,
      decimalsHex: "0x6", rawValueHex: "0x5f5e100",
      uniqueIdSuffix: "1")

    let built = try await TransferEventBuilder().build(
      transfers: [ethOut, usdcIn],
      account: account,
      services: BuilderServices(
        chain: .ethereum, discovery: subject.service, alchemy: alchemy),
      importOrigin: origin)

    let candidate = try #require(built.first)
    let legs = candidate.transaction.legs
    #expect(legs.count == 3)

    let tradeLegs = legs.filter { $0.type == .trade }
    let expenseLegs = legs.filter { $0.type == .expense }
    #expect(tradeLegs.count == 2)
    #expect(expenseLegs.count == 1)

    let gasLeg = try #require(expenseLegs.first)
    #expect(gasLeg.externalId == "0xswap:gas")
    #expect(gasLeg.instrument == ChainConfig.ethereum.nativeInstrument)
    #expect(gasLeg.quantity == -Self.expectedGasFeeEth)

    #expect(candidate.transaction.isTrade)
  }

  @Test("3-leg basket swap → 3 .trade legs + gas, isTrade==false")
  func threeLegBasketSwapKeepsAllTradeLegs() async throws {
    let subject = makeDiscoverySubject()
    subject.resolver.script(
      .init(chainId: 1, contractAddress: Self.usdcAddress.lowercased()),
      .success(coingecko: "usd-coin", binance: nil))
    subject.resolver.script(
      .init(chainId: 1, contractAddress: Self.proveAddress.lowercased()),
      .success(coingecko: "prove", binance: nil))

    let alchemy = RecordingAlchemyClientStub()
    alchemy.setReceiptResponse(
      .receipt(
        AlchemyTransactionReceipt(
          hash: "0xbasket",
          gasUsed: Self.gasUsed,
          effectiveGasPrice: Self.gasPrice,
          from: Self.wallet)),
      for: "0xbasket")

    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)
    let origin = makeWalletImportOrigin(for: account.id)
    let ethOut = makeAlchemyTransfer(
      hash: "0xbasket", from: Self.wallet, to: Self.counterparty,
      category: .external, uniqueIdSuffix: "0")
    let usdcIn = makeAlchemyTransfer(
      hash: "0xbasket", from: Self.counterparty, to: Self.wallet,
      category: .erc20, asset: "USDC",
      contractAddress: Self.usdcAddress,
      decimalsHex: "0x6", rawValueHex: "0x5f5e100",
      uniqueIdSuffix: "1")
    let proveIn = makeAlchemyTransfer(
      hash: "0xbasket", from: Self.counterparty, to: Self.wallet,
      category: .erc20, asset: "PROVE",
      contractAddress: Self.proveAddress,
      decimalsHex: "0x12", rawValueHex: "0x0de0b6b3a7640000",
      uniqueIdSuffix: "2")

    let built = try await TransferEventBuilder().build(
      transfers: [ethOut, usdcIn, proveIn],
      account: account,
      services: BuilderServices(
        chain: .ethereum, discovery: subject.service, alchemy: alchemy),
      importOrigin: origin)

    let candidate = try #require(built.first)
    let legs = candidate.transaction.legs
    #expect(legs.count == 4)
    #expect(legs.filter { $0.type == .trade }.count == 3)
    #expect(legs.filter { $0.type == .expense }.count == 1)
    // 3 trade legs => Transaction.isTrade requires exactly 2 → false.
    #expect(!candidate.transaction.isTrade)
  }

  @Test("Pure inbound transfer → leg stays .income, no receipt fetch, no gas leg")
  func pureInboundLeavesIncome() async throws {
    let subject = makeDiscoverySubject()
    let alchemy = ZeroReceiptAlchemyStub()
    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)
    let origin = makeWalletImportOrigin(for: account.id)
    let inbound = makeAlchemyTransfer(
      hash: "0xpure-inbound",
      from: Self.counterparty,
      to: Self.wallet,
      category: .external)

    let built = try await TransferEventBuilder().build(
      transfers: [inbound],
      account: account,
      services: BuilderServices(
        chain: .ethereum, discovery: subject.service, alchemy: alchemy),
      importOrigin: origin)

    let candidate = try #require(built.first)
    #expect(candidate.transaction.legs.count == 1)
    #expect(candidate.transaction.legs.first?.type == .income)
    #expect(alchemy.recordedReceiptCalls.isEmpty)
  }

  @Test("Pure outbound transfer (no inbound peer) → leg stays .expense + gas")
  func pureOutboundLeavesExpense() async throws {
    let subject = makeDiscoverySubject()
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setReceiptResponse(
      .receipt(
        AlchemyTransactionReceipt(
          hash: "0xpure-out",
          gasUsed: Self.gasUsed,
          effectiveGasPrice: Self.gasPrice,
          from: Self.wallet)),
      for: "0xpure-out")
    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)
    let origin = makeWalletImportOrigin(for: account.id)
    let outbound = makeAlchemyTransfer(
      hash: "0xpure-out",
      from: Self.wallet,
      to: Self.counterparty,
      category: .external)

    let built = try await TransferEventBuilder().build(
      transfers: [outbound],
      account: account,
      services: BuilderServices(
        chain: .ethereum, discovery: subject.service, alchemy: alchemy),
      importOrigin: origin)

    let candidate = try #require(built.first)
    let legs = candidate.transaction.legs
    #expect(legs.count == 2)
    #expect(legs.contains { $0.type == .expense && $0.externalId == "0xpure-out:0" })
    #expect(legs.contains { $0.type == .expense && $0.externalId == "0xpure-out:gas" })
  }

  @Test("Same-instrument inbound + outbound on one hash → legs stay .income / .expense")
  func sameInstrumentBothSidesPassesThroughBuilder() async throws {
    // Single account, single hash: 2 ETH inbound + 1 ETH outbound. Same
    // instrument on both sides, so the swap predicate's ≥2 distinct
    // instruments guard rejects the trigger; legs flow through with
    // their per-direction types from `legType(for:)`.
    let subject = makeDiscoverySubject()
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setReceiptResponse(
      .receipt(
        AlchemyTransactionReceipt(
          hash: "0xsame-instrument",
          gasUsed: Self.gasUsed,
          effectiveGasPrice: Self.gasPrice,
          from: Self.wallet)),
      for: "0xsame-instrument")

    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)
    let origin = makeWalletImportOrigin(for: account.id)
    let inbound = makeAlchemyTransfer(
      hash: "0xsame-instrument",
      from: Self.counterparty,
      to: Self.wallet,
      category: .external,
      uniqueIdSuffix: "0")
    let outbound = makeAlchemyTransfer(
      hash: "0xsame-instrument",
      from: Self.wallet,
      to: Self.counterparty,
      category: .external,
      uniqueIdSuffix: "1")

    let built = try await TransferEventBuilder().build(
      transfers: [inbound, outbound],
      account: account,
      services: BuilderServices(
        chain: .ethereum, discovery: subject.service, alchemy: alchemy),
      importOrigin: origin)

    let candidate = try #require(built.first)
    let legs = candidate.transaction.legs
    #expect(legs.count == 3)
    let inboundLeg = try #require(
      legs.first(where: { $0.externalId == "0xsame-instrument:0" }))
    let outboundLeg = try #require(
      legs.first(where: { $0.externalId == "0xsame-instrument:1" }))
    let gasLeg = try #require(
      legs.first(where: { $0.externalId == "0xsame-instrument:gas" }))
    #expect(inboundLeg.type == .income)
    #expect(outboundLeg.type == .expense)
    #expect(gasLeg.type == .expense)
    #expect(!candidate.transaction.legs.contains { $0.type == .trade })
  }
}
