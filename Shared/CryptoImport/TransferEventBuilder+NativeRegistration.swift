// Shared/CryptoImport/TransferEventBuilder+NativeRegistration.swift
import Foundation

extension TransferEventBuilder {
  /// Maps a transfer's direction onto the leg type the wallet importer
  /// emits per account. `.transfer` is reserved for cross-account
  /// pairs that `CrossAccountTransferMerger` pairs by `externalId` —
  /// individual wallet movements still bookkeep as income / expense
  /// from the synced account's perspective (see issue #791).
  /// - `.outbound`: this wallet paid out → `.expense`
  /// - `.inbound`: this wallet received → `.income`
  /// - `.selfSend`: net-zero against this wallet; positive quantity
  ///   per `signAndCounterparty`, typed as `.income`.
  /// - `.unrelated`: filtered upstream, `signAndCounterparty` returns
  ///   nil before this is reached.
  static func legType(for direction: TransferDirection) -> TransactionType {
    switch direction {
    case .outbound: .expense
    case .inbound: .income
    case .selfSend: .income
    case .unrelated: .income  // unreachable, signAndCounterparty filters it
    }
  }

  /// Pre-register the chain's native gas instrument via discovery so
  /// the registry stores a row carrying a real provider mapping.
  ///
  /// Both transfer-leg construction (`.external` / `.internal` cases
  /// of `resolveInstrument`) and gas-leg construction
  /// (`TransferReceiptCoalescer.makeGasLeg`) use
  /// `chain.nativeInstrument` directly. Without this pre-registration,
  /// `ensureInstrumentReadable` inserts a placeholder `InstrumentRow`
  /// with default `pricingStatus=.priced` and no provider mapping,
  /// which `allCryptoRegistrations()` then projects to nil — and the
  /// downstream conversion throws `ConversionError.noProviderMapping`.
  ///
  /// `resolveOrLoad` canonicalizes the incoming `(chainId, nil)` pair
  /// before persisting: Optimism/Base native ETH collapses onto
  /// `1:native` (the mainnet canonical id), so the registry always
  /// stores a single row per asset regardless of which L2 triggered
  /// the pre-registration. See issue #791.
  ///
  /// Idempotent at the discovery actor: when a registration already
  /// exists for the chain's native id, `resolveOrLoad` short-circuits
  /// to the registry and skips network resolution.
  static func preregisterChainNativeInstrument(
    chain: ChainConfig,
    discovery: CryptoTokenDiscoveryService
  ) async throws {
    let nativeInstrument = chain.nativeInstrument
    _ = try await discovery.resolveOrLoad(
      chain: chain,
      contractAddress: nil,
      symbol: nativeInstrument.ticker ?? nativeInstrument.name,
      name: nativeInstrument.name,
      decimals: nativeInstrument.decimals)
  }
}
