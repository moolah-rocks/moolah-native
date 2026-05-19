import Foundation
import Testing

@testable import Moolah

/// The wrapped-native trust list must match ONLY on an exact
/// `(chainId, contractAddress)` pair — never on symbol/name. A token
/// that merely calls itself "WETH" must not be treated as 1:1
/// redeemable for the chain's native asset (it could be a malicious
/// look-alike that never returns the ETH).
@Suite("WrappedNativeContracts")
struct WrappedNativeContractsTests {
  @Test("Canonical Ethereum WETH resolves to the chain's native id")
  func canonicalWethEthereum() {
    let id = WrappedNativeContracts.nativePricingInstrumentId(
      chainId: 1, contractAddress: "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2")
    #expect(id == "1:native")
  }

  @Test("Address match is case-insensitive (checksummed input)")
  func checksummedAddressStillMatches() {
    let id = WrappedNativeContracts.nativePricingInstrumentId(
      chainId: 1, contractAddress: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2")
    #expect(id == "1:native")
  }

  @Test("Canonical Polygon WMATIC resolves to Polygon native id")
  func canonicalWmaticPolygon() {
    let id = WrappedNativeContracts.nativePricingInstrumentId(
      chainId: 137, contractAddress: "0x0d500b1d8e8ef31e21c99d1db9a6444d3adf1270")
    #expect(id == "137:native")
  }

  @Test("A non-canonical address on a known chain does NOT match (anti-spoof)")
  func lookAlikeContractRejected() {
    let id = WrappedNativeContracts.nativePricingInstrumentId(
      chainId: 1, contractAddress: "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef")
    #expect(id == nil)
  }

  @Test("Right address but wrong chain does NOT match")
  func addressOnWrongChainRejected() {
    // Ethereum WETH address queried as if on Polygon — not the
    // canonical Polygon wrapped-native, so no 1:1 native guarantee.
    let id = WrappedNativeContracts.nativePricingInstrumentId(
      chainId: 137, contractAddress: "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2")
    #expect(id == nil)
  }

  @Test("Native instruments (no contract address) are not remapped")
  func nativeIsNotRemapped() {
    #expect(
      WrappedNativeContracts.nativePricingInstrumentId(chainId: 1, contractAddress: nil) == nil)
  }

  @Test("Inverse accessor yields the canonical wrapper id for cache eviction")
  func inverseAccessorForKnownChain() {
    #expect(
      WrappedNativeContracts.canonicalWrappedInstrumentId(forChainId: 1)
        == "1:0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2")
    #expect(
      WrappedNativeContracts.canonicalWrappedInstrumentId(forChainId: 137)
        == "137:0x0d500b1d8e8ef31e21c99d1db9a6444d3adf1270")
  }

  @Test("Inverse accessor is nil for chains with no listed wrapper")
  func inverseAccessorForUnknownChain() {
    #expect(WrappedNativeContracts.canonicalWrappedInstrumentId(forChainId: 999) == nil)
    #expect(WrappedNativeContracts.canonicalWrappedInstrumentId(forChainId: nil) == nil)
  }
}
