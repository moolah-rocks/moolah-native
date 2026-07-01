// MoolahTests/Shared/CryptoImport/ChainConfigTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("ChainConfig")
struct ChainConfigTests {
  @Test
  func ethereumConfigIsCorrect() {
    let config = ChainConfig.ethereum
    #expect(config.chainId == 1)
    #expect(config.alchemyNetworkSlug == "eth-mainnet")
    #expect(config.supportsInternalTransfers == false)
    #expect(config.displayName == "Ethereum")
    #expect(config.blockExplorerBaseURL.absoluteString == "https://etherscan.io")
    #expect(config.blockscoutAPIBaseURL.absoluteString == "https://eth.blockscout.com")
    #expect(config.nativeInstrument.ticker == "ETH")
    #expect(config.nativeInstrument.chainId == 1)
    #expect(config.nativeInstrument.contractAddress == nil)
    #expect(config.nativeInstrument.decimals == 18)
  }

  @Test
  func optimismConfigIsCorrect() {
    let config = ChainConfig.optimism
    #expect(config.chainId == 10)
    #expect(config.alchemyNetworkSlug == "opt-mainnet")
    #expect(config.supportsInternalTransfers == false)
    #expect(config.displayName == "OP Mainnet")
    #expect(config.blockExplorerBaseURL.absoluteString == "https://optimistic.etherscan.io")
    #expect(config.blockscoutAPIBaseURL.absoluteString == "https://explorer.optimism.io")
    #expect(config.nativeInstrument.ticker == "ETH")
    #expect(config.nativeInstrument.id == "1:native")  // canonical mainnet ETH (§3.1)
    #expect(config.nativeInstrument.chainId == 1)  // canonical mainnet ETH — chain-of-holding is on the account (§2/§3.1)
  }

  @Test
  func baseConfigIsCorrect() {
    let config = ChainConfig.base
    #expect(config.chainId == 8453)
    #expect(config.alchemyNetworkSlug == "base-mainnet")
    #expect(config.supportsInternalTransfers == false)
    #expect(config.displayName == "Base")
    #expect(config.blockExplorerBaseURL.absoluteString == "https://basescan.org")
    #expect(config.blockscoutAPIBaseURL.absoluteString == "https://base.blockscout.com")
    #expect(config.nativeInstrument.ticker == "ETH")
    #expect(config.nativeInstrument.id == "1:native")  // canonical mainnet ETH (§3.1)
    #expect(config.nativeInstrument.chainId == 1)  // canonical mainnet ETH — chain-of-holding is on the account (§2/§3.1)
  }

  @Test
  func allChainsAreUniqueAndComplete() {
    let chainIds = ChainConfig.all.map(\.chainId)
    #expect(Set(chainIds).count == chainIds.count)
    #expect(chainIds == [1, 10, 8453])
  }

  @Test
  func lookupByIdReturnsMatchingConfig() {
    #expect(ChainConfig.config(for: 1) == .ethereum)
    #expect(ChainConfig.config(for: 10) == .optimism)
    #expect(ChainConfig.config(for: 8453) == .base)
  }

  @Test
  func lookupByIdReturnsNilForUnsupportedChain() {
    #expect(ChainConfig.config(for: 0) == nil)
    #expect(ChainConfig.config(for: 137) == nil)  // Polygon (no public Blockscout — unsupported)
    #expect(ChainConfig.config(for: 42_161) == nil)  // Arbitrum, not yet supported
    #expect(ChainConfig.config(for: 999_999) == nil)
  }

  @Test
  func nativeInstrumentsUseCorrectFactoryFormat() {
    // ETH L2 native instruments canonicalize to mainnet ETH (1:native) per design §3.1.
    // Chain-of-holding is carried by the account, not the instrument (design §2).
    #expect(ChainConfig.ethereum.nativeInstrument.id == "1:native")
    #expect(ChainConfig.optimism.nativeInstrument.id == "1:native")
    #expect(ChainConfig.base.nativeInstrument.id == "1:native")
  }

  @Test("L2 native instruments match the resolver's static canonical map")
  func l2NativeMatchesResolverStaticMap() {
    // Drift guard: if CanonicalInstrumentResolver.staticBaseMap ever changes its ETH
    // L2 entries, this test will catch the divergence from the hardcoded ChainConfig values.
    let resolver = CanonicalInstrumentResolver()
    #expect(ChainConfig.optimism.nativeInstrument.id == resolver.canonicalId(for: "10:native"))
    #expect(ChainConfig.base.nativeInstrument.id == resolver.canonicalId(for: "8453:native"))
  }

  @Test
  func l1DataFeeMatchesOPStackChains() {
    // OP-stack rollups (Optimism, Base) post calldata to Ethereum L1
    // and charge an L1 data fee on top of L2 execution; Ethereum does
    // not. This invariant gates whether `makeGasLeg` adds
    // `receipt.l1FeeWei` to the gas-leg quantity (#920).
    let charges = Dictionary(
      uniqueKeysWithValues: ChainConfig.all.map { ($0.chainId, $0.chargesL1DataFee) }
    )
    #expect(charges[1] == false)
    #expect(charges[10] == true)
    #expect(charges[8453] == true)
  }

  @Test
  func internalTransferSupportPerChain() {
    // Blockscout is the authoritative internal-ETH source for all supported chains;
    // no chain requests the Alchemy `internal` category.
    // Polygon (chain 137) has no public Blockscout instance and is not a supported chain.
    let supports = Dictionary(
      uniqueKeysWithValues: ChainConfig.all.map { ($0.chainId, $0.supportsInternalTransfers) }
    )
    #expect(supports[1] == false)
    #expect(supports[10] == false)
    #expect(supports[8453] == false)
    #expect(supports[137] == nil)  // Polygon (no public Blockscout — unsupported)
  }
}
