// MoolahTests/Shared/CryptoImport/JSONRPCEnvelopeTests.swift
import Foundation
import Testing

@testable import Moolah

/// Contract tests for the generic JSON-RPC 2.0 request/response envelope.
/// Pins the exact wire shape (single request and batch array encoding),
/// the out-of-order response correlation `correlate(requests:responses:)`
/// performs, and the `result: null` + `error` decoding path.
@Suite("JSONRPCEnvelope")
struct JSONRPCEnvelopeTests {
  // MARK: - Fixtures

  /// Minimal `Encodable & Sendable` params — an empty array, matching
  /// `eth_chainId`'s no-argument call shape.
  private struct EmptyParams: Encodable, Sendable {}

  /// Minimal `Decodable & Sendable` result — a single hex string, matching
  /// `eth_chainId`'s result shape.
  private struct HexResult: Decodable, Sendable, Equatable {
    let value: String
  }

  // MARK: - Encoding

  /// Asserts on the decoded key/value pairs of a single JSON-RPC request
  /// object rather than a literal string. `JSONEncoder` does not guarantee
  /// key order matches declaration order (Apple's newer Foundation
  /// serializes keyed containers unordered unless `.sortedKeys` is set),
  /// so a byte-exact string comparison would be flaky on implementation
  /// details rather than on our wire shape.
  private func decodeObject(_ data: Data) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: data)
    return try #require(object as? [String: Any])
  }

  @Test("A single request encodes to the exact JSON-RPC 2.0 shape")
  func singleRequestEncodesToExactShape() throws {
    let request = JSONRPCRequest(id: 1, method: "eth_chainId", params: [String]())
    let data = try JSONEncoder().encode(request)
    let object = try decodeObject(data)
    #expect(object.count == 4)
    #expect(object["jsonrpc"] as? String == "2.0")
    #expect(object["id"] as? Int == 1)
    #expect(object["method"] as? String == "eth_chainId")
    #expect((object["params"] as? [String])?.isEmpty == true)
  }

  @Test("A batch of two requests encodes to a top-level JSON array")
  func batchEncodesToJSONArray() throws {
    let requests = [
      JSONRPCRequest(id: 1, method: "eth_chainId", params: [String]()),
      JSONRPCRequest(id: 2, method: "eth_blockNumber", params: [String]()),
    ]
    let data = try JSONEncoder().encode(requests)
    let array = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    #expect(array.count == 2)
    // Array element order is semantically meaningful (unlike object key
    // order) — the JSON-RPC spec correlates batch position loosely via
    // `id`, but we still expect our own encoder to preserve the caller's
    // array order rather than reshuffle it.
    #expect(array[0]["id"] as? Int == 1)
    #expect(array[0]["method"] as? String == "eth_chainId")
    #expect(array[1]["id"] as? Int == 2)
    #expect(array[1]["method"] as? String == "eth_blockNumber")
  }

  // MARK: - Decoding

  @Test("A result envelope with result: null and an error object decodes error non-nil")
  func nullResultWithErrorDecodesErrorNonNil() throws {
    let json = Data(
      """
      {"id":1,"result":null,"error":{"code":-32600,"message":"Invalid Request"}}
      """.utf8)
    let response = try JSONDecoder().decode(JSONRPCResponse<HexResult>.self, from: json)
    #expect(response.result == nil)
    #expect(response.error == JSONRPCError(code: -32600, message: "Invalid Request"))
  }

  @Test("A successful response decodes result non-nil and error nil")
  func successfulResponseDecodesResultNonNilErrorNil() throws {
    let json = Data(
      """
      {"id":1,"result":{"value":"0x1"},"error":null}
      """.utf8)
    let response = try JSONDecoder().decode(JSONRPCResponse<HexResult>.self, from: json)
    #expect(response.result == HexResult(value: "0x1"))
    #expect(response.error == nil)
  }

  // MARK: - correlate(requests:responses:)

  @Test("Responses out of id order are re-correlated to request order")
  func outOfOrderResponsesAreReCorrelatedToRequestOrder() throws {
    let requests = [
      JSONRPCRequest(id: 1, method: "eth_chainId", params: [String]()),
      JSONRPCRequest(id: 2, method: "eth_blockNumber", params: [String]()),
      JSONRPCRequest(id: 3, method: "eth_gasPrice", params: [String]()),
    ]
    // Provider returns them scrambled and reversed relative to request order.
    let responses = [
      JSONRPCResponse(id: 3, result: HexResult(value: "0x3"), error: nil),
      JSONRPCResponse(id: 1, result: HexResult(value: "0x1"), error: nil),
      JSONRPCResponse(id: 2, result: HexResult(value: "0x2"), error: nil),
    ]
    let correlated = try JSONRPCEnvelope.correlate(requests: requests, responses: responses)
    #expect(correlated.map { $0.result?.value } == ["0x1", "0x2", "0x3"])
  }

  @Test("A response id with no matching request throws batchIdMismatch")
  func mismatchedResponseIdThrows() throws {
    let requests = [
      JSONRPCRequest(id: 1, method: "eth_chainId", params: [String]())
    ]
    let responses = [
      JSONRPCResponse(id: 99, result: HexResult(value: "0x1"), error: nil)
    ]
    #expect(throws: JSONRPCTransportError.self) {
      try JSONRPCEnvelope.correlate(requests: requests, responses: responses)
    }
  }

  @Test("A missing response for a requested id throws batchIdMismatch")
  func missingResponseThrows() throws {
    let requests = [
      JSONRPCRequest(id: 1, method: "eth_chainId", params: [String]()),
      JSONRPCRequest(id: 2, method: "eth_blockNumber", params: [String]()),
    ]
    let responses = [
      JSONRPCResponse(id: 1, result: HexResult(value: "0x1"), error: nil)
    ]
    #expect(throws: JSONRPCTransportError.self) {
      try JSONRPCEnvelope.correlate(requests: requests, responses: responses)
    }
  }

  @Test("A duplicate response id throws batchIdMismatch")
  func duplicateResponseIdThrows() throws {
    // A single request (id 1) paired with two responses that both claim id
    // 1. The unique-id count (1) would coincidentally equal
    // `requests.count` (1), so this path is only caught by the explicit
    // duplicate-id guard, not the response-count check below it.
    let requests = [
      JSONRPCRequest(id: 1, method: "eth_chainId", params: [String]())
    ]
    let responses = [
      JSONRPCResponse(id: 1, result: HexResult(value: "0x1"), error: nil),
      JSONRPCResponse(id: 1, result: HexResult(value: "0x1"), error: nil),
    ]
    #expect(throws: JSONRPCTransportError.batchIdMismatch) {
      try JSONRPCEnvelope.correlate(requests: requests, responses: responses)
    }
  }
}
