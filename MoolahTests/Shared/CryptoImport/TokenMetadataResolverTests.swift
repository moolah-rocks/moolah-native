// MoolahTests/Shared/CryptoImport/TokenMetadataResolverTests.swift
import Foundation
import Testing

@testable import Moolah

/// Covers `TokenMetadataResolver`'s ABI decoding (`decimals()`/`symbol()`
/// via `eth_call`) and its per-contract cache for the well-behaved paths:
/// happy-path resolution, cache/in-flight coalescing, and revert/malformed
/// responses. Hostile-contract ABI-overflow decoding and
/// transient-failure negative-caching coverage lives in
/// `TokenMetadataResolverHostileTests`, split out to keep each
/// suite under the file-length/type-body-length thresholds; both share
/// fixtures via `TokenMetadataResolverTestSupport`.
@Suite("TokenMetadataResolver", .serialized)
struct TokenMetadataResolverTests {
  private typealias Support = TokenMetadataResolverTestSupport

  // MARK: - Happy path

  @Test
  func resolvesDecimalsAndSymbol() async throws {
    let resolver = Support.makeResolver { request in
      guard let selector = Support.selector(from: request) else {
        Issue.record("Missing eth_call selector in request body")
        throw URLError(.unknown)
      }
      switch selector {
      case Support.decimalsSelector:
        return Support.okResponse(
          for: request, body: #"{"jsonrpc":"2.0","id":1,"result":"0x6"}"#)
      case Support.symbolSelector:
        return Support.okResponse(
          for: request,
          body:
            #"{"jsonrpc":"2.0","id":1,"result":"\#(Support.abiEncodedString("USDC"))"}"#)
      default:
        Issue.record("Unexpected selector \(selector)")
        throw URLError(.unknown)
      }
    }
    let metadata = await resolver.metadata(for: Support.contract)
    #expect(metadata == .init(decimals: 6, symbol: "USDC"))
  }

  // MARK: - Cache coalescing

  @Test
  func secondLookupForSameContractIssuesNoNewCall() async throws {
    let resolver = Support.makeResolver { request in
      guard let selector = Support.selector(from: request) else {
        Issue.record("Missing eth_call selector in request body")
        throw URLError(.unknown)
      }
      switch selector {
      case Support.decimalsSelector:
        return Support.okResponse(
          for: request, body: #"{"jsonrpc":"2.0","id":1,"result":"0x12"}"#)
      case Support.symbolSelector:
        return Support.okResponse(
          for: request,
          body:
            #"{"jsonrpc":"2.0","id":1,"result":"\#(Support.abiEncodedString("WETH"))"}"#)
      default:
        Issue.record("Unexpected selector \(selector)")
        throw URLError(.unknown)
      }
    }
    let first = await resolver.metadata(for: Support.contract)
    #expect(first == .init(decimals: 18, symbol: "WETH"))
    let callsAfterFirstLookup = TokenMetadataResolverURLProtocolStub.requestCount
    #expect(callsAfterFirstLookup == 2)  // one for decimals, one for symbol

    let second = await resolver.metadata(for: Support.contract)
    #expect(second == .init(decimals: 18, symbol: "WETH"))
    #expect(TokenMetadataResolverURLProtocolStub.requestCount == callsAfterFirstLookup)
  }

  @Test
  func lookupIsCaseInsensitiveOnContractAddress() async throws {
    let resolver = Support.makeResolver { request in
      guard let selector = Support.selector(from: request) else {
        Issue.record("Missing eth_call selector in request body")
        throw URLError(.unknown)
      }
      switch selector {
      case Support.decimalsSelector:
        return Support.okResponse(
          for: request, body: #"{"jsonrpc":"2.0","id":1,"result":"0x6"}"#)
      case Support.symbolSelector:
        return Support.okResponse(
          for: request,
          body:
            #"{"jsonrpc":"2.0","id":1,"result":"\#(Support.abiEncodedString("USDC"))"}"#)
      default:
        Issue.record("Unexpected selector \(selector)")
        throw URLError(.unknown)
      }
    }
    _ = await resolver.metadata(for: Support.contract.lowercased())
    let callsAfterFirstLookup = TokenMetadataResolverURLProtocolStub.requestCount
    let second = await resolver.metadata(for: Support.contract.uppercased())
    #expect(second == .init(decimals: 6, symbol: "USDC"))
    #expect(TokenMetadataResolverURLProtocolStub.requestCount == callsAfterFirstLookup)
  }

  // MARK: - Revert / malformed

  @Test
  func decimalsRevertResolvesToNil() async throws {
    let resolver = Support.makeResolver { request in
      guard let selector = Support.selector(from: request) else {
        Issue.record("Missing eth_call selector in request body")
        throw URLError(.unknown)
      }
      switch selector {
      case Support.decimalsSelector:
        return Support.okResponse(
          for: request,
          body: #"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"execution reverted"}}"#
        )
      default:
        Issue.record("symbol() should not be called when decimals() fails")
        throw URLError(.unknown)
      }
    }
    let metadata = await resolver.metadata(for: Support.contract)
    #expect(metadata == nil)
  }

  @Test
  func decimalsRevertIsCachedAsNilWithoutReissuingTheCall() async throws {
    let resolver = Support.makeResolver { request in
      guard let selector = Support.selector(from: request), selector == Support.decimalsSelector
      else {
        Issue.record("Only decimals() should ever be called for a broken contract")
        throw URLError(.unknown)
      }
      return Support.okResponse(
        for: request,
        body: #"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"execution reverted"}}"#)
    }
    let first = await resolver.metadata(for: Support.contract)
    #expect(first == nil)
    let callsAfterFirstLookup = TokenMetadataResolverURLProtocolStub.requestCount

    let second = await resolver.metadata(for: Support.contract)
    #expect(second == nil)
    #expect(TokenMetadataResolverURLProtocolStub.requestCount == callsAfterFirstLookup)
  }

  @Test
  func emptyDecimalsResultResolvesToNil() async throws {
    let resolver = Support.makeResolver { request in
      guard let selector = Support.selector(from: request), selector == Support.decimalsSelector
      else {
        Issue.record("symbol() should not be called when decimals() is empty")
        throw URLError(.unknown)
      }
      return Support.okResponse(for: request, body: #"{"jsonrpc":"2.0","id":1,"result":"0x"}"#)
    }
    let metadata = await resolver.metadata(for: Support.contract)
    #expect(metadata == nil)
  }

  @Test
  func symbolRevertYieldsNilSymbolButKeepsDecimals() async throws {
    let resolver = Support.makeResolver { request in
      guard let selector = Support.selector(from: request) else {
        Issue.record("Missing eth_call selector in request body")
        throw URLError(.unknown)
      }
      switch selector {
      case Support.decimalsSelector:
        return Support.okResponse(
          for: request, body: #"{"jsonrpc":"2.0","id":1,"result":"0x8"}"#)
      case Support.symbolSelector:
        return Support.okResponse(
          for: request,
          body: #"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"execution reverted"}}"#
        )
      default:
        Issue.record("Unexpected selector \(selector)")
        throw URLError(.unknown)
      }
    }
    let metadata = await resolver.metadata(for: Support.contract)
    #expect(metadata == .init(decimals: 8, symbol: nil))
  }

  @Test
  func legacyBytes32SymbolDecodesAsRightPaddedASCII() async throws {
    // MKR-style legacy encoding: symbol() returns a fixed bytes32, not the
    // standard dynamic string — just the right-zero-padded ASCII bytes with
    // no offset/length prefix.
    let bytes32Symbol =
      "0x4d4b520000000000000000000000000000000000000000000000000000000000"
    let resolver = Support.makeResolver { request in
      guard let selector = Support.selector(from: request) else {
        Issue.record("Missing eth_call selector in request body")
        throw URLError(.unknown)
      }
      switch selector {
      case Support.decimalsSelector:
        return Support.okResponse(
          for: request, body: #"{"jsonrpc":"2.0","id":1,"result":"0x12"}"#)
      case Support.symbolSelector:
        return Support.okResponse(
          for: request,
          body: #"{"jsonrpc":"2.0","id":1,"result":"\#(bytes32Symbol)"}"#)
      default:
        Issue.record("Unexpected selector \(selector)")
        throw URLError(.unknown)
      }
    }
    let metadata = await resolver.metadata(for: Support.contract)
    #expect(metadata == .init(decimals: 18, symbol: "MKR"))
  }
}
