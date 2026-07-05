// Shared/CryptoImport/JSONRPC/JSONRPCEnvelope.swift
import Foundation

/// Generic JSON-RPC 2.0 request envelope, shared across any direct-RPC
/// provider (as opposed to `AlchemyJSONRPCWireFormat`'s Alchemy-specific,
/// fixed-`id`-of-1 variant). `id` is assigned by the caller so a batch of
/// requests can be correlated back to their responses via
/// `JSONRPCEnvelope.correlate(requests:responses:)` — providers are free to
/// return batch results in any order.
struct JSONRPCRequest<Params: Encodable & Sendable>: Encodable, Sendable {
  let jsonrpc: String
  let id: Int
  let method: String
  let params: Params

  init(id: Int, method: String, params: Params) {
    self.jsonrpc = "2.0"
    self.id = id
    self.method = method
    self.params = params
  }
}

/// Generic JSON-RPC 2.0 response envelope. Both `result` and `error` are
/// optional per the spec: a successful call decodes `result` non-nil and
/// `error` nil; a failed call decodes `result` as `null` (or absent) and
/// `error` non-nil.
struct JSONRPCResponse<Result: Decodable & Sendable>: Decodable, Sendable {
  let id: Int
  let result: Result?
  let error: JSONRPCError?
}

/// JSON-RPC 2.0 error object — the `code`/`message` pair the spec defines
/// for the `error` key of a response envelope.
struct JSONRPCError: Decodable, Sendable, Equatable {
  let code: Int
  let message: String
}

/// Errors from correlating a JSON-RPC batch's responses back to its
/// requests — distinct from `JSONRPCError`, which is a well-formed
/// per-call error the *provider* returns inside a response envelope.
enum JSONRPCTransportError: Error {
  /// The response array didn't contain exactly one response per request
  /// id — either a response id had no matching request, or a requested id
  /// had no response.
  case batchIdMismatch
}

/// Namespace for JSON-RPC batch helpers shared across direct-RPC providers.
enum JSONRPCEnvelope {
  /// Re-correlates a batch `responses` array to `requests` order by `id`.
  ///
  /// The JSON-RPC 2.0 spec allows a batch provider to return responses in
  /// any order, so callers must not assume `responses[i]` answers
  /// `requests[i]`. This walks `requests` and looks up each one's response
  /// by `id`, producing an array in request order.
  ///
  /// Throws `.batchIdMismatch` if the two arrays don't correspond
  /// one-to-one by id — a response with an id no request asked for, a
  /// request with no matching response, or (as a consequence of both
  /// checks) a size mismatch between the two arrays.
  static func correlate<Params, Result>(
    requests: [JSONRPCRequest<Params>],
    responses: [JSONRPCResponse<Result>]
  ) throws -> [JSONRPCResponse<Result>] {
    var responsesById: [Int: JSONRPCResponse<Result>] = [:]
    responsesById.reserveCapacity(responses.count)
    for response in responses {
      // A duplicate id is as much a correlation failure as a missing one —
      // reserve the slot on first sight and reject the batch if reuse the
      // caller can't have intended slips through the guard below.
      guard responsesById.updateValue(response, forKey: response.id) == nil else {
        throw JSONRPCTransportError.batchIdMismatch
      }
    }
    guard responsesById.count == requests.count else {
      throw JSONRPCTransportError.batchIdMismatch
    }
    return try requests.map { request in
      guard let response = responsesById[request.id] else {
        throw JSONRPCTransportError.batchIdMismatch
      }
      return response
    }
  }
}
