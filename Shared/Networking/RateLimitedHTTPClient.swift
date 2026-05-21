import Foundation
import OSLog

private let rateLimitedHTTPLogger = Logger(
  subsystem: "com.moolah.app", category: "RateLimitedHTTP")

/// Composes URLSession + a host-shared RateLimitGate + a process-shared
/// FailedRequestCache. Bound to one host at construction time (`gate` is
/// the gate for that host, as vended by `NetworkingServices`).
///
/// `data(for:)` runs pre-flight checks (host gate, per-URL failure cache),
/// dispatches the request, classifies the response, and either returns the
/// 2xx or 304 response or throws — see method doc. Callers never have to repeat the
/// `(200...299).contains(http.statusCode)` boilerplate.
///
/// See `guides/CONCURRENCY_GUIDE.md` §4 sanctioned shape #1.
struct RateLimitedHTTPClient: Sendable {
  private let session: URLSession
  private let gate: RateLimitGate
  private let failureCache: FailedRequestCache

  init(session: URLSession, gate: RateLimitGate, failureCache: FailedRequestCache) {
    self.session = session
    self.gate = gate
    self.failureCache = failureCache
  }

  /// Sends `request` respecting the host gate and per-URL failure cache.
  ///
  /// **Pre-flight:**
  /// - If the gate is in cooldown, throws `RateLimitGateError.cooldown(until:)`.
  /// - If the cache has a live entry for the URL, throws `FailedRequestCacheError.cooldown(until:)`.
  ///
  /// **Post-flight:**
  /// - 2xx or 304 → records success on gate + cache, returns `(Data, HTTPURLResponse)`.
  ///   304 is treated as a well-behaved server response; callers that send
  ///   conditional GETs detect "not modified" via `response.statusCode`.
  /// - 429 / 418 → trips the gate (`Retry-After` or exponential backoff),
  ///   records on cache, throws `RateLimitGateError.cooldown`.
  /// - 503 with `Retry-After` → trips the gate, records on cache,
  ///   throws `RateLimitGateError.cooldown`.
  /// - Any other non-2xx/non-304 (incl. 503 without `Retry-After`, 4xx, 5xx) →
  ///   records on cache, throws `URLError(.badServerResponse)`.
  /// - Transport failure (DNS, offline, timeout, hangup; not cancellation)
  ///   → records on cache, rethrows the original error.
  /// - Cancellation (`CancellationError` or `URLError(.cancelled)`) →
  ///   propagates without muting the URL.
  ///
  /// Unlike the legacy per-call pattern, non-2xx throws
  /// `URLError(.badServerResponse)` rather than returning `(data, response)`
  /// for the caller to check. Every previous call site implemented exactly
  /// that check, so the consolidated behavior is a pure DRY-out.
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    try await gate.ensureAvailable()
    let cacheKey = request.url?.absoluteString
    if let cacheKey {
      try await failureCache.ensureAvailable(for: cacheKey)
    }
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      if !Self.isCancellation(error), let cacheKey {
        let deadline = await failureCache.recordTransportFailure(for: cacheKey)
        rateLimitedHTTPLogger.notice(
          """
          Transport failure for \(request.url?.host ?? "?", privacy: .public): \
          \(error.localizedDescription, privacy: .public); URL muted \
          until \(deadline.timeIntervalSince1970, privacy: .public)
          """
        )
      }
      throw error
    }
    let http = try await Self.classify(
      response: response,
      request: request,
      cacheKey: cacheKey,
      gate: gate,
      failureCache: failureCache
    )
    return (data, http)
  }

  /// Classifies the response and records gate/cache side effects.
  /// Throws `RateLimitGateError.cooldown` for rate-limit responses,
  /// `URLError(.badServerResponse)` for any other non-2xx/non-304, and returns
  /// the `HTTPURLResponse` for 2xx or 304.
  ///
  /// 304 Not Modified is treated as a successful response (the server is
  /// well-behaved) — it records success on the gate and failure cache and
  /// returns the response so callers that send conditional GETs can detect the
  /// "not modified" outcome via `statusCode`.
  private static func classify(
    response: URLResponse,
    request: URLRequest,
    cacheKey: String?,
    gate: RateLimitGate,
    failureCache: FailedRequestCache
  ) async throws -> HTTPURLResponse {
    guard let http = response as? HTTPURLResponse else {
      throw URLError(.badServerResponse)
    }
    let retryAfter = http.retryAfterSeconds(now: Date())
    let host = request.url?.host ?? "?"
    switch http.statusCode {
    case 200...299, 304:
      await gate.recordSuccess()
      if let cacheKey {
        await failureCache.recordSuccess(for: cacheKey)
      }
      return http
    case 429, 418:
      try await tripGate(
        outcome: .init(retryAfter: retryAfter, statusCode: http.statusCode, host: host),
        cacheKey: cacheKey,
        gate: gate,
        failureCache: failureCache
      )
    case 503 where retryAfter != nil:
      try await tripGate(
        outcome: .init(retryAfter: retryAfter, statusCode: http.statusCode, host: host),
        cacheKey: cacheKey,
        gate: gate,
        failureCache: failureCache
      )
    default:
      if let cacheKey {
        let deadline = await failureCache.recordHTTPFailure(for: cacheKey)
        rateLimitedHTTPLogger.notice(
          """
          Request failed (HTTP \(http.statusCode, privacy: .public)) for \
          \(host, privacy: .public); URL muted until \
          \(deadline.timeIntervalSince1970, privacy: .public)
          """
        )
      }
      throw URLError(.badServerResponse)
    }
  }

  private struct RateLimitOutcome {
    let retryAfter: TimeInterval?
    let statusCode: Int
    let host: String
  }

  private static func tripGate(
    outcome: RateLimitOutcome,
    cacheKey: String?,
    gate: RateLimitGate,
    failureCache: FailedRequestCache
  ) async throws -> Never {
    let deadline = await gate.recordRateLimit(retryAfter: outcome.retryAfter)
    if let cacheKey {
      await failureCache.recordHTTPFailure(for: cacheKey)
    }
    rateLimitedHTTPLogger.warning(
      """
      Rate-limited (HTTP \(outcome.statusCode, privacy: .public)) by \
      \(outcome.host, privacy: .public); cooldown until \
      \(deadline.timeIntervalSince1970, privacy: .public)
      """
    )
    throw RateLimitGateError.cooldown(until: deadline)
  }

  private static func isCancellation(_ error: any Error) -> Bool {
    if error is CancellationError { return true }
    if let urlError = error as? URLError, urlError.code == .cancelled { return true }
    return false
  }

  // MARK: - Test seam (internal)

  /// The injected `URLSession`. Internal so tests can assert pass-through.
  var underlyingSession: URLSession { session }
}
