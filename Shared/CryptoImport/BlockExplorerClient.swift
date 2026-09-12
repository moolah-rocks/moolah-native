// Shared/CryptoImport/BlockExplorerClient.swift
import Foundation
import OSLog
import os

/// Block-explorer source for native-ETH enumeration. Blockscout's
/// public API is indexed by *transaction* (and exposes
/// contract-internal transfers), so unlike Alchemy's Transfer-log
/// index it surfaces zero-value / `approve()` / failed signed txs
/// (#919) and OP-stack internal ETH credits (#918). No API key — the
/// public instances are unauthenticated.
protocol BlockExplorerClient: Sendable {
  /// Every transaction touching `walletAddress` (as `from` or `to`),
  /// newest-first, paginated until the cursor is absent or a page
  /// predates `fromBlock`. Includes failed / zero-value / `approve()`
  /// txs — they are real signed txs that paid gas.
  func nativeTransactions(
    chain: ChainConfig, walletAddress: String, fromBlock: UInt64
  ) async throws -> [BlockscoutTransaction]

  /// Contract-internal ETH transfers touching `walletAddress`, same
  /// pagination contract. This is the data Alchemy cannot index on
  /// OP-stack chains (#918).
  func internalTransactions(
    chain: ChainConfig, walletAddress: String, fromBlock: UInt64
  ) async throws -> [BlockscoutInternalTx]
}

/// Live `BlockExplorerClient` over Blockscout's public v2 REST API.
/// `Sendable` struct with no mutable state — mirrors `LiveAlchemyClient`.
struct LiveBlockscoutClient: Sendable {
  private let session: URLSession
  private let rateLimiter: RateLimiter
  private let retryPolicy: HTTPRetryPolicy
  private let sleeper: @Sendable (TimeInterval) async throws -> Void
  private let logger: Logger

  init(
    session: URLSession = APIHTTPSession.shared,
    rateLimiter: RateLimiter,
    retryPolicy: HTTPRetryPolicy = HTTPRetryPolicy(
      honorsRetryAfterInPlace: true),
    sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = {
      try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000))
    }
  ) {
    self.session = session
    self.rateLimiter = rateLimiter
    self.retryPolicy = retryPolicy
    self.sleeper = sleeper
    self.logger = Logger(subsystem: "com.moolah.app", category: "BlockscoutClient")
  }

  // MARK: - Internals

  // Per-endpoint configuration for the generic Blockscout cursor-loop paginator: the URL path
  // suffix, log-stage tag, page decoder, item accessor, cursor extractor, and per-item
  // block-number accessor for one paginated Blockscout endpoint.
  private struct PaginateConfig<Page, Item> {
    let pathSuffix: String
    let stage: String
    let decode: (Data) throws -> Page
    let items: (Page) -> [Item]
    let cursor: (Page) -> BlockscoutPageParams?
    let blockNumber: (Item) -> Int
  }

  /// Generic cursor loop shared by both endpoints. Stops when the cursor
  /// is absent, when a page is empty, when a `BlockscoutPageParams` cursor
  /// repeats (misbehaving provider guard, mirrors `LiveAlchemyClient`), or
  /// once every item on a page predates `fromBlock` (newest-first ordering
  /// means nothing older remains worth fetching).
  private func paginate<Page, Item>(
    chain: ChainConfig,
    walletAddress: String,
    fromBlock: UInt64,
    config: PaginateConfig<Page, Item>
  ) async throws -> [Item] {
    let signpostID = OSSignpostID(log: Signposts.cryptoSync)
    os_signpost(
      .begin,
      log: Signposts.cryptoSync,
      name: "blockscout.fetch",
      signpostID: signpostID,
      "chain %{public}d",
      chain.chainId)
    defer {
      os_signpost(
        .end,
        log: Signposts.cryptoSync,
        name: "blockscout.fetch",
        signpostID: signpostID)
    }
    var collected: [Item] = []
    var pageParams: BlockscoutPageParams?
    var seenCursors: Set<BlockscoutPageParams> = []
    while true {
      // Explicit per-iteration cancellation check (don't rely on the rate limiter's).
      try Task.checkCancellation()
      if let pageParams, !seenCursors.insert(pageParams).inserted { break }
      try await rateLimiter.acquire()
      let request = try buildRequest(
        chain: chain,
        walletAddress: walletAddress,
        pathSuffix: config.pathSuffix,
        pageParams: pageParams)
      let data = try await send(request: request, stage: config.stage)
      let page: Page
      do {
        page = try config.decode(data)
      } catch {
        logger.error(
          "Blockscout \(config.stage, privacy: .public) decode failed for chain \(chain.chainId, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
        throw WalletSyncError.providerMalformedResponse(stage: config.stage)
      }
      let pageItems = config.items(page)
      if pageItems.isEmpty { break }
      collected.append(contentsOf: pageItems)
      // Newest-first: if the whole page is older than fromBlock, stop.
      if pageItems.allSatisfy({ UInt64(config.blockNumber($0).magnitude) < fromBlock }) {
        break
      }
      guard let next = config.cursor(page) else { break }
      pageParams = next
    }
    return collected
  }

  private func buildRequest(
    chain: ChainConfig,
    walletAddress: String,
    pathSuffix: String,
    pageParams: BlockscoutPageParams?
  ) throws -> URLRequest {
    guard
      var components = URLComponents(
        url: chain.blockscoutAPIBaseURL, resolvingAgainstBaseURL: false)
    else {
      throw WalletSyncError.network(
        underlyingDescription: "Malformed Blockscout base URL for chain \(chain.chainId)")
    }
    components.path = "/api/v2/addresses/\(walletAddress)/\(pathSuffix)"
    let cursorItems = pageParams?.queryItems ?? []
    components.queryItems = cursorItems.isEmpty ? nil : cursorItems
    guard let url = components.url else {
      throw WalletSyncError.network(
        underlyingDescription: "Malformed Blockscout URL for chain \(chain.chainId)")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    // Hash/address is `.private`; chain is `.public` — matches the
    // Alchemy client's privacy table.
    logger.debug(
      "Blockscout GET chain \(chain.chainId, privacy: .public) \(pathSuffix, privacy: .public) address \(walletAddress, privacy: .private) paged \(pageParams != nil, privacy: .public)"
    )
    return request
  }

  private func send(request: URLRequest, stage: String) async throws -> Data {
    let timed: URLRequest = {
      var request = request
      request.timeoutInterval = retryPolicy.requestTimeout
      return request
    }()
    do {
      return try await withRetry(
        policy: retryPolicy,
        classify: { HTTPRetryClassifier.decision(for: $0, idempotent: true) },
        sleep: sleeper,
        operation: { @Sendable in
          try await self.attempt(request: timed, stage: stage)
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
          "Blockscout \(stage, privacy: .public) rate-limit retry exhausted (Retry-After \(retryAfter, privacy: .public)s)"
        )
        throw WalletSyncError.rateLimited(
          retryAfter: Date().addingTimeInterval(retryAfter))
      }
      logger.error(
        "Blockscout \(stage, privacy: .public) retry exhausted (server error)"
      )
      throw WalletSyncError.network(
        underlyingDescription: "retry exhausted (server error)")
    } catch {
      logger.error(
        "Blockscout \(stage, privacy: .public) network failure: \(error.localizedDescription, privacy: .public)"
      )
      throw WalletSyncError.network(
        underlyingDescription: error.localizedDescription)
    }
  }

  /// One transport attempt. Returns body on 2xx; throws `HTTPRetrySignal` when
  /// the response is retryable, or a terminal `WalletSyncError` otherwise. A
  /// raw transient `URLError` propagates so the classifier can retry it.
  private func attempt(request: URLRequest, stage: String) async throws -> Data {
    let (data, response) = try await session.data(for: request)
    try classifyBlockscout(response: response, stage: stage)
    return data
  }

  /// Blockscout-specific HTTP status classification: 2xx is success;
  /// 429/418/503 (and other 5xx) become an `HTTPRetrySignal` so `withRetry`
  /// can retry or wait; everything else is a terminal `WalletSyncError`.
  private func classifyBlockscout(
    response: URLResponse, stage: String
  ) throws {
    guard let http = response as? HTTPURLResponse else {
      throw WalletSyncError.network(underlyingDescription: "No HTTP response")
    }
    let retryAfter = http.retryAfterSeconds(now: Date())
    switch http.statusCode {
    case 200...299:
      return
    case 401, 403:
      logger.error(
        "Blockscout \(stage, privacy: .public): HTTP 401/403 (public API expects no auth)"
      )
      throw WalletSyncError.network(underlyingDescription: "HTTP 401/403")
    case 429, 418:
      if retryPolicy.honorsRetryAfterInPlace, let wait = retryAfter,
        wait <= retryPolicy.maxRateLimitWait
      {
        throw HTTPRetrySignal(retryAfter: wait)
      }
      throw WalletSyncError.rateLimited(
        retryAfter: retryAfter.map { Date().addingTimeInterval($0) })
    case 503:
      if retryPolicy.honorsRetryAfterInPlace, let wait = retryAfter,
        wait <= retryPolicy.maxRateLimitWait
      {
        throw HTTPRetrySignal(retryAfter: wait)
      }
      if let retryAfter {
        throw WalletSyncError.rateLimited(
          retryAfter: Date().addingTimeInterval(retryAfter))
      }
      throw HTTPRetrySignal(retryAfter: nil)
    case 500...599:
      throw HTTPRetrySignal(retryAfter: nil)
    default:
      logger.error(
        "Blockscout \(stage, privacy: .public): HTTP \(http.statusCode, privacy: .public)"
      )
      throw WalletSyncError.network(
        underlyingDescription: "HTTP \(http.statusCode)")
    }
  }
}

extension LiveBlockscoutClient: BlockExplorerClient {
  func nativeTransactions(
    chain: ChainConfig, walletAddress: String, fromBlock: UInt64
  ) async throws -> [BlockscoutTransaction] {
    try await attributingErrors(to: .blockExplorer) {
      try await paginate(
        chain: chain,
        walletAddress: walletAddress,
        fromBlock: fromBlock,
        config: PaginateConfig(
          pathSuffix: "transactions",
          stage: "blockscout.transactions",
          decode: { try JSONDecoder().decode(BlockscoutTransactionsPage.self, from: $0) },
          items: { $0.items },
          cursor: { $0.nextPageParams },
          blockNumber: { $0.blockNumber }))
    }
  }

  func internalTransactions(
    chain: ChainConfig, walletAddress: String, fromBlock: UInt64
  ) async throws -> [BlockscoutInternalTx] {
    try await attributingErrors(to: .blockExplorer) {
      try await paginate(
        chain: chain,
        walletAddress: walletAddress,
        fromBlock: fromBlock,
        config: PaginateConfig(
          pathSuffix: "internal-transactions",
          stage: "blockscout.internalTransactions",
          decode: { try JSONDecoder().decode(BlockscoutInternalTxPage.self, from: $0) },
          items: { $0.items },
          cursor: { $0.nextPageParams },
          blockNumber: { $0.blockNumber }))
    }
  }
}
