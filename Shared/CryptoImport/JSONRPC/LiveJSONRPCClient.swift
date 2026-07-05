// Shared/CryptoImport/JSONRPC/LiveJSONRPCClient.swift
import Foundation
import OSLog

/// Live JSON-RPC 2.0 client over a single, caller-injected node endpoint —
/// no per-chain slug and no API key in the URL, unlike `LiveAlchemyClient`.
/// `Sendable` struct with no mutable state, mirroring `LiveAlchemyClient` /
/// `LiveBlockscoutClient`'s transport shape.
///
/// Transport combines both existing live clients' conventions:
/// `send(request:stage:)` wraps `withRetry` with `rateLimiter.acquire()`
/// **inside** the retried operation (as `LiveAlchemyClient` does), but HTTP
/// status classification honours `Retry-After` **in place** for 429/5xx
/// responses (as `LiveBlockscoutClient` does for public, unauthenticated
/// endpoints) rather than always failing to a fixed exponential backoff.
///
/// Only `chainId()` and `blockNumber()` ship in this task. `send`/`call` are
/// structured so `getLogs`, `blockTimestamps` (batch), `call(to:data:)`, and
/// `transactionReceipt(hash:)` extend cleanly in later tasks without
/// reshaping the transport.
struct LiveJSONRPCClient: Sendable {
  private let endpoint: URL
  private let session: URLSession
  private let rateLimiter: RateLimiter
  /// Injected sleep for the retry backoff so tests drive the retry loop
  /// without real wall-clock delay. Live callers get `Task.sleep`.
  private let sleeper: @Sendable (TimeInterval) async throws -> Void
  private let logger: Logger

  /// - Parameters:
  ///   - endpoint: The JSON-RPC node URL every request POSTs to. Injected
  ///     rather than derived from a chain slug — this client is used for
  ///     both custom user-supplied endpoints and default public nodes.
  ///   - session: `URLSession` for HTTP requests. Default is `.shared`;
  ///     tests inject an ephemeral session backed by `URLProtocol`.
  ///   - rateLimiter: Shared `RateLimiter` actor — caller sizes it to the
  ///     endpoint in use.
  ///   - sleeper: Backoff sleep for the retry loop. Defaults to
  ///     `Task.sleep`; tests pass an instant no-op.
  init(
    endpoint: URL,
    session: URLSession = .shared,
    rateLimiter: RateLimiter,
    sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = {
      try await Task.sleep(nanoseconds: UInt64($0 * 1e9))
    }
  ) {
    self.endpoint = endpoint
    self.session = session
    self.rateLimiter = rateLimiter
    self.sleeper = sleeper
    self.logger = Logger(subsystem: "com.moolah.app", category: "LiveJSONRPCClient")
  }

  /// Bounded backoff for residual rate-limiting: 1 initial attempt + 3
  /// retries, exponential (0.5s base, 8s cap). Unlike `LiveAlchemyClient`'s
  /// fixed-provider policy, this endpoint is user-supplied and often a
  /// public node, so a `Retry-After` no longer than 60s is honoured and
  /// waited out in place — matching `LiveBlockscoutClient`'s policy for
  /// public, unauthenticated instances.
  private static let retryPolicy = HTTPRetryPolicy(
    maxAttempts: 4,
    backoffBase: 0.5,
    backoffCap: 8,
    honorsRetryAfterInPlace: true,
    maxRateLimitWait: 60)

  // MARK: - Public methods

  func chainId() async throws -> Int {
    let hex: String = try await call(method: "eth_chainId", params: [String](), stage: "chainId")
    guard let value = RPCHex.parseUInt64(hex), let chainId = Int(exactly: value) else {
      logger.error("JSON-RPC chainId: malformed hex quantity \(hex, privacy: .public)")
      throw WalletSyncError.providerMalformedResponse(stage: "chainId")
    }
    return chainId
  }

  func blockNumber() async throws -> UInt64 {
    let hex: String = try await call(
      method: "eth_blockNumber", params: [String](), stage: "blockNumber")
    guard let value = RPCHex.parseUInt64(hex) else {
      logger.error("JSON-RPC blockNumber: malformed hex quantity \(hex, privacy: .public)")
      throw WalletSyncError.providerMalformedResponse(stage: "blockNumber")
    }
    return value
  }

  // MARK: - Internals

  /// One JSON-RPC round-trip: encodes `{method, params}` as a single (non-batch)
  /// request with a fixed `id: 1` — every call is its own HTTP request, so there
  /// is no batch to correlate by id. Decodes the response envelope, throwing
  /// `.providerMalformedResponse(stage:)` when the body carries a JSON-RPC
  /// `error` object, when `result` is `null`, or when decoding itself fails.
  private func call<Params: Encodable & Sendable, ResultValue: Decodable & Sendable>(
    method: String,
    params: Params,
    stage: String
  ) async throws -> ResultValue {
    let requestBody = JSONRPCRequest(id: 1, method: method, params: params)
    let request = try buildRequest(body: requestBody)
    logger.debug("JSON-RPC \(stage, privacy: .public): \(method, privacy: .public)")
    let data = try await send(request: request, stage: stage)
    return try decodeResponse(data, stage: stage)
  }

  private func decodeResponse<ResultValue: Decodable & Sendable>(
    _ data: Data, stage: String
  ) throws -> ResultValue {
    let envelope: JSONRPCResponse<ResultValue>
    do {
      envelope = try JSONDecoder().decode(JSONRPCResponse<ResultValue>.self, from: data)
    } catch {
      logger.error(
        "JSON-RPC \(stage, privacy: .public) decode failed: \(error.localizedDescription, privacy: .public)"
      )
      throw WalletSyncError.providerMalformedResponse(stage: stage)
    }
    if let error = envelope.error {
      logger.error(
        "JSON-RPC \(stage, privacy: .public) provider error \(error.code, privacy: .public): \(error.message, privacy: .public)"
      )
      throw WalletSyncError.providerMalformedResponse(stage: stage)
    }
    guard let result = envelope.result else {
      logger.error("JSON-RPC \(stage, privacy: .public): result is null with no error")
      throw WalletSyncError.providerMalformedResponse(stage: stage)
    }
    return result
  }

  private func buildRequest<Params: Encodable & Sendable>(
    body: JSONRPCRequest<Params>
  ) throws -> URLRequest {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    do {
      request.httpBody = try JSONEncoder().encode(body)
    } catch {
      throw WalletSyncError.providerMalformedResponse(stage: "encodeRequestBody")
    }
    return request
  }

  /// Sends `request` through the shared `withRetry` backoff, with
  /// `rateLimiter.acquire()` sitting *inside* the retried operation so every
  /// attempt — including retries — is spaced by the same shared
  /// `RateLimiter`; a retry can't bypass the de-burst and re-create a
  /// simultaneous fan-out. `classify` defers to the shared
  /// `HTTPRetryClassifier`, which retries transient transport errors and any
  /// `HTTPRetrySignal` the response classifier raises.
  private func send(request: URLRequest, stage: String) async throws -> Data {
    do {
      return try await withRetry(
        policy: Self.retryPolicy,
        classify: { HTTPRetryClassifier.decision(for: $0, idempotent: true) },
        sleep: sleeper,
        operation: { @Sendable in
          try await self.rateLimiter.acquire()
          return try await self.attempt(request: request, stage: stage)
        }
      )
    } catch let urlError as URLError where urlError.code == .cancelled {
      throw CancellationError()
    } catch is CancellationError {
      throw CancellationError()
    } catch let walletError as WalletSyncError {
      throw walletError
    } catch let signal as HTTPRetrySignal {
      if let retryAfter = signal.retryAfter {
        logger.error(
          "JSON-RPC \(stage, privacy: .public) rate-limit retry exhausted (Retry-After \(retryAfter, privacy: .public)s)"
        )
        throw WalletSyncError.rateLimited(
          retryAfter: Date().addingTimeInterval(retryAfter))
      }
      logger.error("JSON-RPC \(stage, privacy: .public) retry exhausted (server error)")
      throw WalletSyncError.network(
        underlyingDescription: "retry exhausted (server error)")
    } catch {
      logger.error(
        "JSON-RPC \(stage, privacy: .public) network failure: \(error.localizedDescription, privacy: .public)"
      )
      throw WalletSyncError.network(
        underlyingDescription: error.localizedDescription)
    }
  }

  /// One transport attempt. Returns the body on 2xx; throws `HTTPRetrySignal`
  /// when the response is retryable in place, or a terminal `WalletSyncError`
  /// otherwise. A raw transient `URLError` propagates so the classifier can
  /// retry it.
  private func attempt(request: URLRequest, stage: String) async throws -> Data {
    let (data, response) = try await session.data(for: request)
    try classify(response: response, stage: stage)
    return data
  }

  /// HTTP status classification: 2xx is success; 429 and 5xx become an
  /// `HTTPRetrySignal` (in-place `Retry-After` when it fits the policy's
  /// `maxRateLimitWait`, else policy backoff for 5xx or a terminal
  /// `.rateLimited` for an out-of-budget 429); everything else is a
  /// terminal `.network` error. JSON-RPC's own `{"error": ...}` envelope is
  /// a 200 with an error *body*, not an HTTP status — that's handled by
  /// `decodeResponse`, not here.
  private func classify(response: URLResponse, stage: String) throws {
    guard let http = response as? HTTPURLResponse else {
      throw WalletSyncError.network(underlyingDescription: "No HTTP response")
    }
    let retryAfter = http.retryAfterSeconds(now: Date())
    switch http.statusCode {
    case 200...299:
      return
    case 429:
      if Self.retryPolicy.honorsRetryAfterInPlace, let wait = retryAfter,
        wait <= Self.retryPolicy.maxRateLimitWait
      {
        throw HTTPRetrySignal(retryAfter: wait)
      }
      throw WalletSyncError.rateLimited(
        retryAfter: retryAfter.map { Date().addingTimeInterval($0) })
    case 500...599:
      throw HTTPRetrySignal(retryAfter: nil)
    default:
      logger.error(
        "JSON-RPC \(stage, privacy: .public): HTTP \(http.statusCode, privacy: .public)"
      )
      throw WalletSyncError.network(underlyingDescription: "HTTP \(http.statusCode)")
    }
  }
}
