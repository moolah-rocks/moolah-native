import Foundation
import OSLog

/// Builds `BuiltTransaction` candidates from imported exchange transactions,
/// for the existing `WalletApplyEngine`. Trades (sharing an `orderId`) become
/// one multi-leg `Transaction`; deposits/withdrawals/awards become single-leg
/// transactions. If ANY leg in a group has an unresolvable instrument the
/// WHOLE group is dropped (a partial, unbalanced trade is worse than no
/// trade) and the drop is logged for diagnosis.
///
/// `Sendable` struct with no mutable state — mirrors `WalletSyncEngine` so it
/// is safe to call concurrently from the orchestrator's parallel build phase.
struct ExchangeSyncEngine: Sendable {
  private let resolver: ExchangeInstrumentResolver
  private let discovery: CryptoTokenDiscoveryService
  private let importOriginFactory: @Sendable (UUID) -> ImportOrigin
  /// Shared static `Logger` — `Logger` is `Sendable`, so a static let is
  /// safe across actor boundaries without per-instance allocation.
  private static let logger = Logger(
    subsystem: "com.moolah.app", category: "ExchangeSyncEngine")

  // Canonical multi-chain preference: Ethereum first (product
  // decision), then the wallet-supported chains, then the rest.
  private static let chainPreference: [Int] =
    [1, 10, 8453, 42161, 137, 56, 43114, 100, 250, 59144, 146]

  // Non-EVM natives the app pins by convention, keyed by uppercased
  // symbol. Resolved directly (no getCoinBySymbol call) — these are
  // `CryptoRegistration.builtInPresets` members.
  private static let nonEvmNatives: [String: Instrument] = [
    "BTC": .crypto(
      chainId: 0,
      contractAddress: nil,
      symbol: "BTC",
      name: "Bitcoin",
      decimals: 8)
  ]

  /// - Parameters:
  ///   - resolver: Maps imported asset symbols to canonical `Instrument`s.
  ///   - discovery: Actor-coalesced token registry resolver.
  ///   - importOriginFactory: Builds the `.single` `ImportOrigin` attached
  ///     to every built `Transaction` for one account-sync. Called once
  ///     per `build(account:imported:metadata:)` invocation, so every
  ///     candidate in the same pass shares one `importSessionId` and a
  ///     single `importedAt`. Required (no default): callers must decide
  ///     what audit context the rows carry — production uses
  ///     `parserIdentifier == "coinstash"`, tests pin a deterministic
  ///     clock + session id.
  init(
    resolver: ExchangeInstrumentResolver,
    discovery: CryptoTokenDiscoveryService,
    importOriginFactory: @Sendable @escaping (UUID) -> ImportOrigin
  ) {
    self.resolver = resolver
    self.discovery = discovery
    self.importOriginFactory = importOriginFactory
  }

  // Coinstash category -> Moolah leg type. DEPOSIT/AWARD are inbound
  // (.income); WITHDRAW is outbound (.expense); TRADEFEE is the exchange's
  // cut on a trade (.expense, grouped with its trade by orderId); TRADE and
  // any unmapped category are swap legs (.trade). The signed quantity
  // already encodes direction; this only selects the type bucket the UI
  // groups by.
  private static func legType(for category: String) -> TransactionType {
    switch category {
    case "DEPOSIT", "AWARD": return .income
    case "WITHDRAW", "TRADEFEE": return .expense
    default: return .trade
    }
  }

  /// Runs the build phase for a single exchange account. Returns the
  /// candidate `BuiltTransaction`s; `headBlockNumber` is always `0` for
  /// exchanges (no block-watermark concept — the apply pass dedups by
  /// per-leg `externalId`).
  ///
  /// Cancellation: respects `Task.checkCancellation()` between groups and
  /// per row. A cancelled task throws `CancellationError` and writes nothing
  /// anywhere — the apply pass is the single writer regardless.
  func build(
    account: Account,
    imported: [ExchangeImportedTransaction],
    metadata: any ExchangeAssetMetadataResolving
  ) async throws -> WalletSyncBuildResult {
    // Trades share an `orderId`; deposits/withdrawals/awards have none, so
    // their `externalId` keys a singleton group (one single-leg transaction
    // each).
    let groups = Dictionary(grouping: imported) { $0.orderId ?? $0.externalId }
    // One origin per account-sync: every candidate this pass produces
    // shares the same `importSessionId`, so `RecentlyAddedViewModel`
    // groups them as one session. Built once, before the per-group
    // loop, mirroring `WalletSyncEngine.run(account:)`.
    let importOrigin = importOriginFactory(account.id)
    var candidates: [BuiltTransaction] = []
    for (groupKey, rows) in groups {
      try Task.checkCancellation()
      if let candidate = try await buildCandidate(
        groupKey: groupKey,
        rows: rows,
        account: account,
        metadata: metadata,
        importOrigin: importOrigin)
      {
        candidates.append(candidate)
      }
    }
    Self.logger.info(
      """
      Built \(candidates.count, privacy: .public) candidates from \
      \(imported.count, privacy: .public) imported rows
      """)
    return WalletSyncBuildResult(candidates: candidates, headBlockNumber: 0)
  }

  /// Builds one candidate `BuiltTransaction` for a single `orderId`/
  /// `externalId` group. Returns `nil` (dropping the WHOLE group) on the
  /// first row whose instrument is unresolvable — a partial, unbalanced
  /// trade is worse than no trade — and logs the drop for diagnosis.
  /// `importOrigin` is the per-account-pass origin built by `build`;
  /// every candidate from the same pass shares it.
  private func buildCandidate(
    groupKey: String,
    rows: [ExchangeImportedTransaction],
    account: Account,
    metadata: any ExchangeAssetMetadataResolving,
    importOrigin: ImportOrigin
  ) async throws -> BuiltTransaction? {
    var legs: [TransactionLeg] = []
    for row in rows {
      try Task.checkCancellation()
      guard
        let instrument = try await resolveInstrument(
          symbol: row.assetSymbol, isFiat: row.isFiat, metadata: metadata)
      else {
        Self.logger.warning(
          """
          Dropping group \(groupKey, privacy: .public): unresolvable \
          instrument externalId=\(row.externalId, privacy: .public) \
          symbol=\(row.assetSymbol ?? "nil", privacy: .public) \
          isFiat=\(row.isFiat, privacy: .public)
          """)
        return nil
      }
      // `.trade` legs preserve source-entered signs: CREDIT=+, DEBIT=-.
      // Never abs() and never auto-sign by leg position.
      let quantity = row.direction.multiplier * row.amount
      legs.append(
        TransactionLeg(
          accountId: account.id,
          instrument: instrument,
          quantity: quantity,
          externalId: row.externalId,
          type: Self.legType(for: row.category)))
    }
    // Earliest occurrence in the group dates the transaction; no
    // `Date()` fallback (the group always has at least one row, so
    // `min()` is non-nil here — `guard` documents the invariant).
    guard let date = rows.map(\.occurredAt).min() else { return nil }
    return BuiltTransaction(
      originAccountId: account.id,
      transaction: Transaction(
        date: date, legs: legs, importOrigin: .single(importOrigin)))
  }

  /// Resolution pipeline:
  /// 1. Fiat flag → fiatInstrument.
  /// 2. Non-EVM native (e.g. BTC) → builtInPresets / discovery (no metadata call).
  /// 3. Provider metadata call → discovery with the canonical EVM chain.
  /// 4. Empty chains in metadata → registry fallback (non-EVM, symbol scan).
  /// 5. No metadata at all → registry fallback.
  /// 6. Unresolved → nil (caller drops + logs the group).
  private func resolveInstrument(
    symbol: String?,
    isFiat: Bool,
    metadata: any ExchangeAssetMetadataResolving
  ) async throws -> Instrument? {
    if isFiat { return resolver.fiatDenomination() }
    guard let symbol else { return nil }

    if let native = Self.nonEvmNatives[symbol.uppercased()] {
      guard let chainId = native.chainId, let ticker = native.ticker else {
        preconditionFailure(
          "nonEvmNatives entry \(native.id) must be a crypto instrument with chainId+ticker")
      }
      if let existing = try await resolver.registeredInstrument(id: native.id) {
        return existing
      }
      let reg = try await discovery.resolveOrLoad(
        chainId: chainId,
        contractAddress: nil,
        symbol: ticker,
        name: native.name,
        decimals: native.decimals)
      return reg.instrument
    }

    let meta = try await metadata.assetMetadata(forSymbol: symbol)

    if let meta, let chosen = Self.canonical(meta.chains) {
      let reg = try await discovery.resolveOrLoad(
        chainId: chosen.chainId,
        contractAddress: chosen.contractAddress,
        symbol: meta.symbol,
        name: meta.name,
        decimals: chosen.decimals)
      return reg.instrument
    }

    return try await resolver.fallbackInstrument(forSymbol: symbol)
  }

  private static func canonical(_ chains: [ExchangeAssetChain]) -> ExchangeAssetChain? {
    guard !chains.isEmpty else { return nil }
    for preferred in Self.chainPreference {
      if let hit = chains.first(where: { $0.chainId == preferred }) { return hit }
    }
    return chains.first
  }
}
