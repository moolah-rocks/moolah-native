import Foundation
import OSLog

struct CoinstashClient: ExchangeClient, Sendable {
  typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

  private let transport: Transport
  private static let pageSize = 100
  private static let logger = Logger(
    subsystem: "com.moolah.app", category: "CoinstashClient")

  // Coinstash `Chain` enum → EVM chain id. Non-EVM (SOLANA) and any
  // value absent here are intentionally excluded: a symbol that lists
  // only excluded chains falls through to the caller's registry
  // fallback. `AVALANCE` is Coinstash's spelling.
  private static let evmChainIds: [String: Int] = [
    "ETHEREUM": 1, "OPTIMISM": 10, "BASE": 8453, "ARBITRUM": 42161,
    "POLYGON": 137, "BSC": 56, "AVALANCE": 43114, "GNOSIS": 100,
    "FANTOM": 250, "LINEA": 59144, "SONIC": 146,
  ]

  /// The well-known "native asset" sentinel address (`0x` + forty `e`).
  private static let nativeSentinel = "0x" + String(repeating: "e", count: 40)

  init(
    transport: @escaping Transport = { try await APIHTTPSession.shared.data(for: $0) }
  ) {
    self.transport = transport
  }

  func fetchTransactions(token: String) async throws -> [ExchangeImportedTransaction] {
    let profile = try await query(
      CoinstashGraphQL.userProfileQuery,
      variables: [:],
      token: token,
      decoding: CoinstashUserProfileData.self)
    let userId = profile.userProfile.userId
    try Task.checkCancellation()

    let accountsData = try await query(
      CoinstashGraphQL.userAccountsQuery,
      variables: ["userId": .string(userId)],
      token: token,
      decoding: CoinstashUserAccountsData.self)
    let accounts = accountsData.getUserAccounts.accounts
    try Task.checkCancellation()
    if accounts.count > 1 {
      Self.logger.warning(
        "Coinstash returned \(accounts.count, privacy: .public) accounts; importing the first only")
    }
    guard let accountId = accounts.first?.accountId else { return [] }

    var all: [CoinstashTransaction] = []
    var pageIndex = 0
    while true {
      try Task.checkCancellation()
      let pageData = try await query(
        CoinstashGraphQL.transactionsQuery,
        variables: [
          "a": .string(accountId),
          "p": .object([
            "pageIndex": .int(pageIndex),
            "pageSize": .int(Self.pageSize),
          ]),
        ],
        token: token,
        decoding: CoinstashTransactionsData.self)
      let page = pageData.accountTransactions
      all.append(contentsOf: page.result)
      if all.count >= page.totalRecordsFound || page.result.isEmpty { break }
      pageIndex += 1
    }
    return all.compactMap(Self.map(_:))
  }

  // MARK: - Coin metadata

  /// Token metadata for `symbol`, or `nil` when Coinstash does not
  /// recognise the symbol (definitive — caller takes the registry
  /// fallback). Throws on transport / provider error (transient — the
  /// sync retries). Non-EVM and unknown chains are dropped; the native
  /// sentinel collapses to `contractAddress == nil`; Coinstash's listing
  /// order is preserved.
  func coinMetadata(symbol: String, token: String) async throws -> ExchangeAssetMetadata? {
    let data = try await query(
      CoinstashGraphQL.coinBySymbolQuery,
      variables: ["s": .string(symbol)],
      token: token,
      decoding: CoinstashCoinData.self)
    guard let coin = data.getCoinBySymbol else { return nil }

    let chains: [ExchangeAssetChain] = coin.defiAddresses.compactMap { entry in
      guard let chainId = Self.evmChainIds[entry.chain] else { return nil }
      guard let address = entry.address else { return nil }
      let isSentinel = address.caseInsensitiveCompare(Self.nativeSentinel) == .orderedSame
      return ExchangeAssetChain(
        chainId: chainId,
        contractAddress: isSentinel ? nil : address,
        decimals: entry.decimals ?? 18)  // EVM default; most ERC-20s are 18-decimal
    }
    return ExchangeAssetMetadata(symbol: coin.symbol, name: coin.name, chains: chains)
  }

  // MARK: - Mapping

  private static func map(_ transaction: CoinstashTransaction) -> ExchangeImportedTransaction? {
    guard transaction.transactionStatus == "COMPLETED" else { return nil }
    // ISO8601DateFormatter is not Sendable (an NSObject subclass with mutable
    // internals), so a `static let` on this Sendable struct would be a compile
    // error. A per-call local is the correct spelling — do not hoist to static.
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let occurredAt = formatter.date(from: transaction.transactedOn) else {
      Self.logger.warning(
        "Dropping tx \(transaction.transactionId, privacy: .public): unparseable date '\(transaction.transactedOn, privacy: .public)'"
      )
      return nil
    }
    let direction: ExchangeDirection
    switch transaction.type {
    case "CREDIT": direction = .credit
    case "DEBIT": direction = .debit
    default:
      Self.logger.warning(
        "Dropping tx \(transaction.transactionId, privacy: .public): unrecognised type '\(transaction.type, privacy: .public)'"
      )
      return nil
    }
    // Resolve the instrument from the per-leg `symbol`, NOT `assetSymbol`:
    // `assetSymbol` carries the order's traded asset and is `null` for
    // every DEPOSIT/WITHDRAW/AWARD, which would drop all crypto inward/
    // outward transfers as unresolvable.
    return ExchangeImportedTransaction(
      externalId: transaction.transactionId,
      occurredAt: occurredAt,
      category: transaction.category,
      direction: direction,
      assetSymbol: transaction.symbol,
      amount: transaction.amount,
      isFiat: transaction.amountType == "FIAT",
      orderId: transaction.orderId)
  }

  // MARK: - GraphQL transport

  private func query<T: Decodable & Sendable>(
    _ graphQLQuery: String,
    variables: [String: JSONValue],
    token: String,
    decoding: T.Type
  ) async throws -> T {
    var request = URLRequest(url: CoinstashGraphQL.endpoint)
    request.httpMethod = "POST"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    var body: [String: JSONValue] = ["query": .string(graphQLQuery)]
    if !variables.isEmpty { body["variables"] = .object(variables) }
    request.httpBody = try JSONEncoder().encode(JSONValue.object(body))

    let (data, response) = try await transport(request)
    guard let http = response as? HTTPURLResponse else {
      throw ExchangeClientError.malformedResponse
    }
    switch http.statusCode {
    case 200: break
    case 401: throw ExchangeClientError.unauthorized
    case 429:
      // No proactive client-side rate limiter: Coinstash publishes no limits
      // and an account's history is 1–3 pages. Handle 429 reactively; the
      // store retries on the next cycle.
      throw ExchangeClientError.rateLimited(retryAfter: nil)
    default: throw ExchangeClientError.http(http.statusCode)
    }
    let decoded = try JSONDecoder().decode(
      CoinstashGraphQLResponse<T>.self, from: data)
    if let firstError = decoded.errors.first {
      if firstError.message.localizedCaseInsensitiveContains("unauthor") {
        throw ExchangeClientError.unauthorized
      }
      throw ExchangeClientError.providerError(firstError.message)
    }
    guard let payload = decoded.data else {
      throw ExchangeClientError.malformedResponse
    }
    return payload
  }
}
