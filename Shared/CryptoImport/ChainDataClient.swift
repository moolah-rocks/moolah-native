// Shared/CryptoImport/ChainDataClient.swift
import Foundation
import OSLog
import os

/// Provider-neutral seam for on-chain data (asset transfers and transaction
/// receipts). Alchemy is the only implementation today (`LiveAlchemyClient`);
/// a direct JSON-RPC client is expected to conform later. Public protocol so
/// test stubs can replace the live client. Stage 6's `WalletSyncEngine`
/// injects a `ChainDataClient` rather than a concrete struct; v1 ships only
/// `LiveAlchemyClient` plus per-test stubs.
protocol ChainDataClient: Sendable {
  /// Returns transfers in `[fromBlock, latestBlock]` for `walletAddress`,
  /// in two passes: `fromAddress = walletAddress` and
  /// `toAddress = walletAddress`. Categories include `external` and
  /// `erc20` always; `internal` is included only when
  /// `chain.supportsInternalTransfers` is `true` (currently no supported
  /// chain — Blockscout owns internal ETH on all of them). NFT categories
  /// are always excluded at the request level.
  func getAssetTransfers(
    chain: ChainConfig,
    walletAddress: String,
    fromBlock: UInt64
  ) async throws -> [AlchemyTransfer]

  /// Fetches the on-chain receipt for `hash` so the wallet sync
  /// pipeline can compute the gas-leg quantity (`gasUsed *
  /// effectiveGasPrice`). Alchemy's `alchemy_getAssetTransfers` doesn't
  /// include gas-cost data per transfer, so callers fetch one receipt
  /// per unique outbound `txHash`.
  ///
  /// Throws `WalletSyncError.providerMalformedResponse(stage:
  /// "getTransactionReceipt")` when the JSON-RPC `result` is `null`
  /// (rare — only when the hash isn't on chain yet, or the node has
  /// pruned it) or when the response payload can't be decoded.
  func getTransactionReceipt(
    chain: ChainConfig,
    hash: String
  ) async throws -> AlchemyTransactionReceipt
}

/// The fixed inputs for one direction's paginated transfer fetch.
/// Bundled into a value so the page loop and the per-page round-trip
/// share one parameter instead of threading the same five arguments.
private struct AlchemyTransferQuery: Sendable {
  let chain: ChainConfig
  let address: String
  let isFromAddress: Bool
  let fromBlock: UInt64
  let apiKey: String
}

/// Live `ChainDataClient` over `URLSession`. Sendable struct — no mutable
/// state; mirrors the shape of `Backends/CoinGecko/CoinGeckoClient.swift`.
///
/// Privacy classifications follow the design table:
/// `chainId` and block numbers → `.public`; wallet addresses and contract
/// addresses → `.private`; the API key is never logged.
struct LiveAlchemyClient: Sendable {
  private let session: URLSession
  /// Closure that yields the current Alchemy API key, or `nil` when the
  /// keychain has none. Resolved per-request inside each public method
  /// so a key added in settings *after* the client was constructed is
  /// visible on the next call, and so the client never retains the key
  /// in an instance-level field. The resolved key only lives in the
  /// local stack frame of the in-flight request.
  private let apiKeyProvider: @Sendable () -> String?
  private let rateLimiter: RateLimiter
  /// Injected sleep for the 429 backoff so tests drive the retry loop
  /// without real wall-clock delay. Live callers get `Task.sleep`.
  private let sleeper: @Sendable (TimeInterval) async throws -> Void
  private let logger: Logger

  /// - Parameters:
  ///   - session: `URLSession` for HTTP requests. Default is `.shared`;
  ///     tests inject an ephemeral session backed by `URLProtocol`.
  ///   - apiKeyProvider: Closure invoked at the start of every network
  ///     method. Reads the keychain on each call so a freshly-added key
  ///     is visible without rebuilding the client; never caches the
  ///     value on the struct. Never logged.
  ///   - rateLimiter: Shared `RateLimiter` actor — caller is responsible
  ///     for sizing it to the Alchemy plan in use. Wire it with a small
  ///     `burstCapacity` so the launch-time fan-out across accounts is
  ///     spaced rather than fired as a single burst.
  ///   - sleeper: Backoff sleep for the 429 retry loop. Defaults to
  ///     `Task.sleep`; tests pass an instant no-op.
  init(
    session: URLSession = .shared,
    apiKeyProvider: @escaping @Sendable () -> String?,
    rateLimiter: RateLimiter,
    sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = {
      try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
    }
  ) {
    self.session = session
    self.apiKeyProvider = apiKeyProvider
    self.rateLimiter = rateLimiter
    self.sleeper = sleeper
    self.logger = Logger(subsystem: "com.moolah.app", category: "LiveAlchemyClient")
  }

  private func fetchReceipt(
    chain: ChainConfig,
    hash: String
  ) async throws -> AlchemyTransactionReceipt {
    let apiKey = try resolveApiKey()
    let signpostID = OSSignpostID(log: Signposts.cryptoSync)
    os_signpost(
      .begin,
      log: Signposts.cryptoSync,
      name: "alchemy.getTransactionReceipt",
      signpostID: signpostID,
      "chain %{public}d",
      chain.chainId)
    defer {
      os_signpost(
        .end,
        log: Signposts.cryptoSync,
        name: "alchemy.getTransactionReceipt",
        signpostID: signpostID)
    }
    let body = AlchemyJSONRPCRequest<AlchemyJSONRPCParams>(
      method: "eth_getTransactionReceipt",
      params: .transactionReceipt(hash: hash)
    )
    let request = try buildRequest(chain: chain, body: body, apiKey: apiKey)
    // Hash is `.private` in logs — pairing a tx hash with the device
    // identifies wallet activity even though the chain itself is public.
    logger.debug(
      "Alchemy getTransactionReceipt: chain \(chain.chainId, privacy: .public) hash \(hash, privacy: .private)"
    )
    let data = try await send(request: request, stage: "getTransactionReceipt")
    do {
      let envelope = try JSONDecoder().decode(
        AlchemyJSONRPCNullableResponse<AlchemyTransactionReceiptPayload>.self,
        from: data
      )
      guard let payload = envelope.result else {
        // `result: null` — happens when the hash isn't on chain (yet) or
        // the node has pruned it. Surface as a malformed-response error
        // so the orchestrator's per-account containment can decide.
        logger.notice(
          "Alchemy getTransactionReceipt returned null result for chain \(chain.chainId, privacy: .public) hash \(hash, privacy: .private)"
        )
        throw WalletSyncError.providerMalformedResponse(stage: "getTransactionReceipt")
      }
      return try payload.toReceipt(hash: hash)
    } catch let error as WalletSyncError {
      throw error
    } catch {
      logger.error(
        "Alchemy getTransactionReceipt decode failed for chain \(chain.chainId, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      throw WalletSyncError.providerMalformedResponse(stage: "getTransactionReceipt")
    }
  }

  // MARK: - Internals

  /// Resolves the current API key from the closure provider and rejects
  /// missing / empty values with `.missingApiKey`. Called at the top of
  /// every public method; the returned string is held only on the local
  /// stack frame and passed down to `fetchTransfers` / `buildRequest`.
  /// The client never stores the resolved value on `self`.
  ///
  /// The wiring at `ProfileSession.makeCryptoSyncWiring` reads the
  /// keychain on each call (rather than at construction) so a key added
  /// in settings *after* the client was built is visible on the next
  /// request. Without this freshness guarantee the user sees Sync now
  /// 401 with a stale empty-string key even after configuring a valid
  /// one.
  private func resolveApiKey() throws -> String {
    let key = apiKeyProvider() ?? ""
    guard !key.isEmpty else { throw WalletSyncError.missingApiKey }
    return key
  }

  /// Follows Alchemy's cursor until all transfers for one direction have been
  /// collected. Truncating at the first page would break balance for wallets
  /// with heavy history.
  private func fetchTransfers(
    _ query: AlchemyTransferQuery
  ) async throws -> [AlchemyTransfer] {
    var collected: [AlchemyTransfer] = []
    var pageKey: String?
    // Guards against a misbehaving provider that returns a `pageKey`
    // already used: re-requesting it would loop forever. Stop before
    // re-fetching a continuation cursor that has already been requested.
    var requestedPageKeys: Set<String> = []
    while true {
      if let pageKey, !requestedPageKeys.insert(pageKey).inserted {
        break
      }
      let result = try await fetchTransferPage(query, pageKey: pageKey)
      collected.append(contentsOf: result.transfers)
      pageKey = result.pageKey
      if pageKey == nil { break }
    }
    return collected
  }

  /// One rate-limited round-trip for a single direction and page.
  private func fetchTransferPage(
    _ query: AlchemyTransferQuery,
    pageKey: String?
  ) async throws -> AlchemyTransferResult {
    let chain = query.chain
    var categories: [AlchemyTransferCategory] = [.external, .erc20]
    if chain.supportsInternalTransfers {
      categories.append(.internal)
    }
    let body = AlchemyJSONRPCRequest<AlchemyJSONRPCParams>(
      method: "alchemy_getAssetTransfers",
      params: .assetTransfers(
        AlchemyAssetTransfersParams(
          fromBlock: "0x" + String(query.fromBlock, radix: 16),
          toBlock: "latest",
          fromAddress: query.isFromAddress ? query.address : nil,
          toAddress: query.isFromAddress ? nil : query.address,
          category: categories.map(\.rawValue),
          withMetadata: true,
          excludeZeroValue: true,
          pageKey: pageKey
        )
      )
    )
    let request = try buildRequest(chain: chain, body: body, apiKey: query.apiKey)
    logger.debug(
      """
      Alchemy getAssetTransfers: chain \(chain.chainId, privacy: .public) \
      direction \(query.isFromAddress ? "from" : "to", privacy: .public) \
      address \(query.address, privacy: .private) \
      fromBlock \(query.fromBlock, privacy: .public) \
      continuation \(pageKey != nil, privacy: .public)
      """
    )

    let data = try await send(request: request, stage: "getAssetTransfers")
    do {
      return try JSONDecoder().decode(
        AlchemyTransferEnvelope.self, from: data
      ).result
    } catch {
      logger.error(
        "Alchemy getAssetTransfers decode failed for chain \(chain.chainId, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      throw WalletSyncError.providerMalformedResponse(stage: "getAssetTransfers")
    }
  }

  /// Sends `request` through the shared `withRetry` backoff, retrying only
  /// Alchemy's own HTTP 429 before surfacing `.rateLimited`. `acquire()` sits
  /// *inside* the retried operation so every attempt — including retries — is
  /// spaced by the same shared `RateLimiter`; a retry can't bypass the
  /// de-burst and re-create the simultaneous fan-out this client is tuned to
  /// avoid. Non-429 errors are classified terminal and propagate on the first
  /// attempt. This is the recovery path for the residual 429s that still slip
  /// through the proactive limiter, so a transient throttle no longer freezes
  /// an account's sync until the next launch.
  private func send(request: URLRequest, stage: String) async throws -> Data {
    try await withRetry(
      policy: Self.retryPolicy,
      classify: { Self.retryDecision(for: $0) },
      sleep: sleeper,
      operation: {
        try await self.rateLimiter.acquire()
        return try await self.performRequest(request, stage: stage)
      }
    )
  }

  /// Bounded backoff for the residual 429s that slip past the proactive
  /// `RateLimiter`: 1 initial attempt + 3 retries, exponential (0.5s base,
  /// 8s cap). Alchemy's 429 carries no `Retry-After`, so in-place honouring
  /// stays off and backoff is always the policy's.
  private static let retryPolicy = HTTPRetryPolicy(
    maxAttempts: 4, backoffBase: 0.5, backoffCap: 8)

  /// Retry only `.rateLimited` (Alchemy's 429). Every other `WalletSyncError`
  /// — and any non-`WalletSyncError` such as `CancellationError` — is terminal
  /// on the first attempt.
  private static func retryDecision(for error: any Error) -> HTTPRetryDecision {
    guard let walletError = error as? WalletSyncError,
      case .rateLimited = walletError.kind
    else { return .doNotRetry }
    return .retryAfterBackoff
  }

  /// One transport attempt: 2xx returns the body; a non-2xx status is mapped
  /// to a typed `WalletSyncError` by `validate`; a cancelled transfer maps to
  /// `CancellationError`; any other transport failure to `.network`.
  private func performRequest(_ request: URLRequest, stage: String) async throws -> Data {
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch let urlError as URLError where urlError.code == .cancelled {
      throw CancellationError()
    } catch {
      logger.error(
        "Alchemy \(stage, privacy: .public) network failure: \(error.localizedDescription, privacy: .public)"
      )
      throw WalletSyncError.network(underlyingDescription: error.localizedDescription)
    }
    try validate(response: response, stage: stage)
    return data
  }

  private func buildRequest<Params: Encodable>(
    chain: ChainConfig,
    body: AlchemyJSONRPCRequest<Params>,
    apiKey: String
  ) throws -> URLRequest {
    let urlString = "https://\(chain.alchemyNetworkSlug).g.alchemy.com/v2/\(apiKey)"
    guard let url = URL(string: urlString) else {
      throw WalletSyncError.network(
        underlyingDescription: "Malformed Alchemy URL for chain \(chain.chainId)"
      )
    }
    var request = URLRequest(url: url)
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

  private func validate(response: URLResponse, stage: String) throws {
    try AlchemyResponseValidator.validate(
      response: response, stage: stage, logger: logger)
  }
}

// MARK: - ChainDataClient

extension LiveAlchemyClient: ChainDataClient {
  func getAssetTransfers(
    chain: ChainConfig,
    walletAddress: String,
    fromBlock: UInt64
  ) async throws -> [AlchemyTransfer] {
    try await attributingErrors(to: .alchemy) {
      let apiKey = try resolveApiKey()
      let signpostID = OSSignpostID(log: Signposts.cryptoSync)
      os_signpost(
        .begin,
        log: Signposts.cryptoSync,
        name: "alchemy.getAssetTransfers",
        signpostID: signpostID,
        "chain %{public}d",
        chain.chainId)
      defer {
        os_signpost(
          .end,
          log: Signposts.cryptoSync,
          name: "alchemy.getAssetTransfers",
          signpostID: signpostID)
      }
      var transfers: [AlchemyTransfer] = []
      for isFromAddress in [true, false] {
        transfers.append(
          contentsOf: try await fetchTransfers(
            AlchemyTransferQuery(
              chain: chain,
              address: walletAddress,
              isFromAddress: isFromAddress,
              fromBlock: fromBlock,
              apiKey: apiKey)))
      }
      return transfers
    }
  }

  func getTransactionReceipt(
    chain: ChainConfig,
    hash: String
  ) async throws -> AlchemyTransactionReceipt {
    try await attributingErrors(to: .alchemy) {
      try await fetchReceipt(chain: chain, hash: hash)
    }
  }
}
