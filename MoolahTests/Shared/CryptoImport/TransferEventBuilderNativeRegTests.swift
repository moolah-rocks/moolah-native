// MoolahTests/Shared/CryptoImport/TransferEventBuilderNativeRegTests.swift
import Foundation
import Testing

@testable import Moolah

/// Coverage for the chain native-gas pre-registration. See issue #791.
@Suite("TransferEventBuilder — native instrument registration")
struct TransferEventBuilderNativeRegTests {
  private static let wallet = "0x1111111111111111111111111111111111111111"
  private static let counterparty = "0x2222222222222222222222222222222222222222"
  private static let usdcAddress = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"

  /// Build must route the chain's native gas instrument through
  /// `discovery.resolveOrLoad` so the registry stores a row with a
  /// real provider mapping. Otherwise `ensureInstrumentReadable`
  /// inserts a placeholder row with no mapping and default
  /// `pricingStatus=.priced`, which `allCryptoRegistrations()`
  /// projects to nil — and downstream conversion of `10:native`
  /// (and other native gas tokens) throws
  /// `ConversionError.noProviderMapping`.
  @Test("Building a native transfer registers the chain's native instrument with a mapping")
  func nativeTransferRegistersChainNativeInstrument() async throws {
    let subject = makeDiscoverySubject()
    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .optimism)
    let origin = makeWalletImportOrigin(for: account.id)
    let transfer = makeAlchemyTransfer(
      hash: "0xnative-send",
      from: Self.wallet,
      to: Self.counterparty,
      category: .external)

    _ = try await TransferEventBuilder().build(
      transfers: [transfer],
      account: account,
      services: BuilderServices(
        chain: .optimism,
        discovery: subject.service,
        alchemy: ZeroReceiptAlchemyStub()),
      importOrigin: origin)

    // After canonicalization, OP native ETH (10:native) is stored under
    // the mainnet canonical id (1:native). The registry must not have a
    // row for the retired id.
    let registration = try #require(
      try await subject.registry.cryptoRegistration(byId: "1:native"))
    // Default resolver scripts `coingecko: "default-id"` for unscripted
    // keys; the assertion is on "mapping populated", not on a specific
    // provider id.
    #expect(registration.mapping.coingeckoId == "default-id")
    #expect(registration.pricingStatus == .priced)
  }

  /// Outbound ERC-20 transfers also pay gas in the native instrument.
  /// Even though `resolveInstrument` doesn't go through the native
  /// branch for the transfer leg here, the gas leg appended in
  /// `buildEvent` references `chain.nativeInstrument` directly — so
  /// the registry still needs the native row populated with a
  /// mapping for the gas leg's later conversion to succeed.
  @Test("Building an ERC-20 transfer also registers the chain's native instrument")
  func erc20TransferRegistersChainNativeInstrument() async throws {
    let subject = makeDiscoverySubject()
    subject.resolver.script(
      .init(chainId: 10, contractAddress: Self.usdcAddress.lowercased()),
      .success(coingecko: "usd-coin", cryptocompare: nil, binance: nil))
    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .optimism)
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

    _ = try await TransferEventBuilder().build(
      transfers: [transfer],
      account: account,
      services: BuilderServices(
        chain: .optimism,
        discovery: subject.service,
        alchemy: ZeroReceiptAlchemyStub()),
      importOrigin: origin)

    // After canonicalization, OP native ETH (10:native) is stored under
    // the mainnet canonical id (1:native). The registry must not have a
    // row for the retired id.
    let native = try #require(
      try await subject.registry.cryptoRegistration(byId: "1:native"))
    #expect(native.mapping.coingeckoId == "default-id")
    #expect(native.pricingStatus == .priced)
  }
}
