import Foundation

/// Provider-neutral refresh machinery shared by the crypto provider catalogs.
/// Implements the staleness gate, the per-endpoint conditional GET (ETag /
/// `If-None-Match`), the 304-aware apply step, and the `last_fetched` /
/// `etag` persistence — all the parts a provider's `refreshIfStale()` would
/// otherwise reimplement.
///
/// `run(…)` deliberately PROPAGATES errors: the caller's actor owns the
/// `do/catch` so a network failure leaves `last_fetched` untouched and the
/// catalog retries on the next launch (see `RefreshableCatalog`).
enum CatalogRefresh {
  /// 24-hour stale-fetch guard. A refresh within this window is a no-op even
  /// if the previous fetch returned 304.
  static let defaultMaxAge: TimeInterval = 24 * 3600

  /// Performs one conditional GET, sending `If-None-Match` when a prior
  /// validator is known. A 200 yields the body and the server's new ETag; a
  /// 304 yields `.notModified`; any other status throws `CatalogError.network`.
  static func fetchConditional(
    http: RateLimitedHTTPClient,
    url: URL,
    ifNoneMatch: String?
  ) async throws -> CatalogFetchOutcome {
    var request = URLRequest(url: url)
    if let ifNoneMatch {
      request.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match")
    }
    request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
    let (data, response) = try await http.data(for: request)
    switch response.statusCode {
    case 200:
      return .ok(data, etag: response.value(forHTTPHeaderField: "ETag"))
    case 304:
      return .notModified
    default:
      throw CatalogError.network("status \(response.statusCode) for \(url.absoluteString)")
    }
  }

  /// Runs a full refresh pass over `endpoints`:
  ///
  /// 1. **Staleness gate** — returns without touching the network if the last
  ///    fetch was within `maxAge` of `now`.
  /// 2. **Conditional GETs** — each endpoint is fetched with its stored ETag.
  ///    `.ok` bodies are collected into a `[key: Data]` dict keyed by the
  ///    endpoint key; `.notModified` contributes nothing (an absent key means
  ///    "no update for that table").
  /// 3. **Apply** — `apply(bodies)` is called with the changed endpoints'
  ///    bodies so the provider can replace exactly the tables that changed.
  /// 4. **Persist** — fresh ETags are written, then `last_fetched` is bumped
  ///    to `now` (always, including an all-304 pass).
  ///
  /// Errors propagate; the caller leaves `last_fetched` untouched on failure.
  static func run(
    database: CatalogDatabase,
    endpoints: [CatalogEndpoint],
    http: RateLimitedHTTPClient,
    maxAge: TimeInterval = defaultMaxAge,
    now: Date,
    apply: ([String: Data]) throws -> Void
  ) async throws {
    if let lastFetched = database.readLastFetched(),
      now.timeIntervalSince(lastFetched) < maxAge
    {
      return
    }

    var bodies: [String: Data] = [:]
    var freshEtags: [String: String?] = [:]
    for endpoint in endpoints {
      let outcome = try await fetchConditional(
        http: http,
        url: endpoint.url,
        ifNoneMatch: database.readEtag(key: endpoint.key)
      )
      switch outcome {
      case let .ok(data, etag):
        bodies[endpoint.key] = data
        freshEtags[endpoint.key] = etag
      case .notModified:
        break
      }
    }

    try apply(bodies)

    for (key, etag) in freshEtags {
      try database.writeEtag(key: key, value: etag)
    }
    try database.writeLastFetched(now)
  }
}
