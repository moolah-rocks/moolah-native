// Shared/CryptoImport/TransferEventBuilder.swift
import Foundation
import OSLog
import os

/// Pure builder that converts raw Alchemy transfers (already grouped by
/// `hash`) into `BuiltTransaction`s. Stateless and `Sendable` — every
/// dependency is supplied per call.
///
/// Produces multi-leg transactions:
/// - One `.income` (inbound), `.expense` (outbound), or `.trade`
///   (intra-account swap, retyped by `IntraAccountSwapDetector`) leg
///   per token movement involving this wallet. Self-send legs stay
///   `.income`.
/// - One `.expense` gas leg in the chain native token, on the from-side
///   wallet only, when this wallet is the sender of an `external`
///   transfer. The receipt fetch is coalesced per unique outbound
///   `txHash` so a single complex transaction with N transfer legs only
///   triggers one `eth_getTransactionReceipt` round-trip.
///
/// Each transfer leg's `externalId` is set to the Alchemy `uniqueId`
/// (`"<hash>:<category>:<index>"`) so a multi-event transaction can
/// produce multiple legs without colliding on the schema's partial
/// unique index `UNIQUE(account_id, external_id)`. The gas leg (built
/// from a single receipt per hash, not from a transfer event) uses
/// `"<hash>:gas"` for the same reason. The hash itself remains the
/// `BlockExplorerLink.transactionURL` key, so dedup on `externalId`
/// and "open in explorer" deliberately differ. The `counterpartyAddress`
/// is the lowercased on-chain address on the *other* side of the transfer:
/// the `to` address for outbound legs, the `from` address for inbound legs,
/// and `nil` for self-sends (where both sides are this wallet) and unknown
/// directions. NFT categories are filtered upstream at the request level; if
/// one slips through (the decoder's lenient `.unknown` case) the builder
/// skips it with a `Logger.notice` and continues so a single bad row doesn't
/// fail the whole sync.
struct TransferEventBuilder: Sendable {
  /// Shared static `Logger` — `Logger` is `Sendable`, so this is safe
  /// across actor boundaries without per-instance allocation.
  private static let logger = Logger(
    subsystem: "com.moolah.app", category: "TransferEventBuilder")

  /// Builds candidate transactions for a single account from a list of
  /// transfers fetched from Alchemy. Resolves token instruments via the
  /// supplied discovery service so concurrent build calls coalesce on
  /// the same `(chainId, contractAddress)` key.
  ///
  /// `account.walletAddress` is the user's wallet on this chain. The
  /// builder lowercases it before comparison — Alchemy returns `from` /
  /// `to` lowercased but callers may have stored the address in
  /// checksummed form. Transfers where `from` matches the wallet are
  /// outbound; matches on `to` are inbound. A self-send (both sides on
  /// this wallet) emits a single inbound leg plus the gas leg — Stage
  /// 7's apply pass pairs the matching outbound from the build phase if
  /// the user happens to track the same wallet under two accounts
  /// (rare).
  ///
  /// `importOrigin` carries the per-import audit context (sync session
  /// id, parser identifier). Caller supplies; the builder echoes it on
  /// every produced transaction.
  ///
  /// `alchemy` is the same client used by `WalletSyncEngine` to fetch
  /// transfers. The builder uses it to fetch one `eth_getTransactionReceipt`
  /// per unique outbound `txHash` so it can attach the gas leg. Receipt
  /// fetches run in parallel via a `TaskGroup`; the rate limiter inside
  /// the live client handles throttling. A receipt-fetch failure for one
  /// hash logs and continues — the affected event ships without a gas
  /// leg rather than failing the whole account.
  ///
  /// Throws: surfaces only `CancellationError` from the discovery actor
  /// and `WalletSyncError.providerMalformedResponse` when a transfer
  /// the builder cannot interpret reaches the produced-leg stage.
  /// Per-row decode failures (malformed hex, missing decimals on a
  /// non-native transfer) are logged and skipped — they shouldn't fail
  /// the whole account.
  ///
  /// `signedGasTxs` is the set of transactions the wallet signed according
  /// to Blockscout's account tx list — including hashes that produced no
  /// Alchemy transfer events (e.g. `approve()`, failed or zero-movement
  /// txs). Each signed tx still paid gas; the builder emits a gas-leg-only
  /// transaction for every such hash. Defaults to `[]` so existing callers
  /// that don't supply Blockscout data remain unaffected.
  ///
  /// `prefetchedReceipts` seeds the internal receipt cache with receipts
  /// the caller already fetched — e.g. `WalletSyncEngine`'s
  /// `WrapUnwrapDetector` pass fetches the receipt for an outbound wrap
  /// candidate, which is also the hash's gas-leg receipt. Seeding here
  /// means the coalescer skips re-fetching that hash. Defaults to `[:]`
  /// so existing callers are unaffected.
  func build(
    transfers: [AlchemyTransfer],
    account: Account,
    services: BuilderServices,
    importOrigin: ImportOrigin,
    signedGasTxs: [SignedGasTx] = [],
    prefetchedReceipts: [String: AlchemyTransactionReceipt] = [:]
  ) async throws -> [BuiltTransaction] {
    let chain = services.chain
    let alchemy = services.alchemy
    let signpostID = OSSignpostID(log: Signposts.cryptoSync)
    os_signpost(
      .begin,
      log: Signposts.cryptoSync,
      name: "transferEventBuilder.build",
      signpostID: signpostID,
      "%{public}d transfers",
      transfers.count)
    defer {
      os_signpost(
        .end,
        log: Signposts.cryptoSync,
        name: "transferEventBuilder.build",
        signpostID: signpostID)
    }
    guard let rawAddress = account.walletAddress else {
      throw WalletSyncError.providerMalformedResponse(stage: "buildEvents-walletAddress")
    }
    let context = BuildContext(
      account: account,
      walletAddress: rawAddress.lowercased(),
      chain: chain,
      discovery: services.discovery,
      importOrigin: importOrigin)
    try await Self.preregisterChainNativeInstrument(chain: chain, discovery: services.discovery)
    return try await buildTransactions(
      transfers: transfers,
      signedGasTxs: signedGasTxs,
      context: context,
      alchemy: alchemy,
      prefetchedReceipts: prefetchedReceipts)
  }

  // MARK: - Internals

  // internal for TransferEventBuilder+GasOnly.swift; not general API
  /// Groups transfers by `hash` while preserving first-seen order so the
  /// emitted `[BuiltTransaction]` is stable across runs (helps with
  /// signpost tracing and snapshot assertions in tests). Each event in a
  /// group already carries its own `hash`, so the key is dropped after
  /// grouping to keep call sites simple.
  func groupByHash(_ transfers: [AlchemyTransfer]) -> [[AlchemyTransfer]] {
    var order: [String] = []
    var buckets: [String: [AlchemyTransfer]] = [:]
    for transfer in transfers {
      if buckets[transfer.hash] == nil {
        order.append(transfer.hash)
      }
      buckets[transfer.hash, default: []].append(transfer)
    }
    return order.compactMap { buckets[$0] }
  }

  // internal for TransferEventBuilder+GasOnly.swift; not general API
  /// Builds one `BuiltTransaction` from a hash group, or returns `nil`
  /// when the group produces no usable legs (every transfer was unknown
  /// category or malformed). Per-event legs are passed through
  /// `IntraAccountSwapDetector.retypeSwapLegs(_:)` before the gas leg
  /// is appended; non-swap hashes pass through unchanged.
  ///
  /// `receipt` is the pre-fetched `eth_getTransactionReceipt` for this
  /// hash, present only when at least one event is an outbound
  /// `external` transfer for this wallet. When present the builder
  /// appends a single `.expense` gas leg in the chain's native token
  /// with `externalId = "<hash>:gas"` — distinct from every transfer
  /// leg's per-event `uniqueId` so the schema's partial unique index
  /// on `(accountId, externalId)` doesn't reject the second insert.
  func buildEvent(
    events: [AlchemyTransfer],
    receipt: AlchemyTransactionReceipt?,
    context: BuildContext
  ) async throws -> BuiltTransaction? {
    var directional: [DirectionalLeg] = []
    var earliestTimestamp: Date?

    for event in events {
      try Task.checkCancellation()
      guard let directionalLeg = try await makeTransferLeg(event: event, context: context)
      else {
        continue
      }
      directional.append(directionalLeg)
      if let timestamp = parseTimestamp(event.metadata.blockTimestamp) {
        if let current = earliestTimestamp {
          earliestTimestamp = min(current, timestamp)
        } else {
          earliestTimestamp = timestamp
        }
      }
    }

    guard !directional.isEmpty else { return nil }

    var legs = IntraAccountSwapDetector.retypeSwapLegs(directional)

    if let receipt,
      let gasLeg = TransferReceiptCoalescer.makeGasLeg(
        receipt: receipt,
        accountId: context.account.id,
        chain: context.chain,
        walletAddress: context.walletAddress)
    {
      legs.append(gasLeg)
    }

    // Date precedence: earliest block timestamp across the group, falling
    // back to `importedAt` so the transaction never lands with a zero
    // date if Alchemy omitted metadata for every event in this hash
    // (possible only when `withMetadata: false`, which the production
    // client doesn't request; guard anyway for defensiveness).
    let date = earliestTimestamp ?? context.importOrigin.importedAt
    let transaction = Transaction(
      date: date,
      legs: legs,
      importOrigin: .single(context.importOrigin))
    return BuiltTransaction(
      originAccountId: context.account.id,
      transaction: transaction)
  }

  /// Builds a `DirectionalLeg` (an `.income` / `.expense` leg per
  /// `legType(for:)` plus the originating `TransferDirection`) for one
  /// Alchemy event, or returns `nil` when the event is unusable (NFT
  /// category slipped through, malformed amount, or a touched-but-not-
  /// on-this-wallet event). The direction is consumed by
  /// `IntraAccountSwapDetector` to partition self-sends out of the
  /// swap predicate without inferring from `counterpartyAddress`.
  private func makeTransferLeg(
    event: AlchemyTransfer,
    context: BuildContext
  ) async throws -> DirectionalLeg? {
    guard event.category != .unknown else {
      Self.logger.notice(
        "Skipping unknown-category transfer hash \(event.hash, privacy: .private)"
      )
      return nil
    }

    let direction = TransferDirection(
      fromAddress: event.from,
      toAddress: event.to,
      walletAddress: context.walletAddress)
    guard direction != .unrelated else {
      // Defensive — Alchemy's two-pass query should never surface a
      // transfer that doesn't touch this wallet, but a malformed reply
      // shouldn't fail the whole sync.
      Self.logger.notice(
        "Skipping transfer not involving wallet for hash \(event.hash, privacy: .private)"
      )
      return nil
    }

    guard
      let unsignedQuantity = scaledQuantity(
        rawDecimalValue: event.rawContract.rawDecimalValue,
        decimalsValue: event.rawContract.decimalsValue,
        category: event.category,
        chain: context.chain)
    else {
      Self.logger.notice(
        "Skipping malformed-amount transfer hash \(event.hash, privacy: .private)"
      )
      return nil
    }

    let instrument = try await resolveInstrument(event: event, context: context)
    guard
      let resolution = signAndCounterparty(
        direction: direction, event: event, magnitude: unsignedQuantity)
    else {
      return nil
    }

    let leg = TransactionLeg(
      accountId: context.account.id,
      instrument: instrument,
      quantity: resolution.signedQuantity,
      externalId: event.uniqueId,
      counterpartyAddress: resolution.counterpartyAddress,
      type: TransferEventBuilder.legType(for: direction))
    return DirectionalLeg(leg: leg, direction: direction)
  }

  /// Resolves a transfer's direction into the leg's signed quantity and
  /// `counterpartyAddress`. Returns `nil` for `.unrelated`, which the
  /// caller has already rejected; included so the function is total.
  ///
  /// The counterparty rule is the four-quadrant truth table from the
  /// builder header: outbound = `to`, inbound = `from`, self-send = nil.
  /// Lowercased everywhere for canonical comparison.
  private func signAndCounterparty(
    direction: TransferDirection,
    event: AlchemyTransfer,
    magnitude: Decimal
  ) -> SignAndCounterparty? {
    switch direction {
    case .outbound:
      return SignAndCounterparty(
        signedQuantity: -magnitude, counterpartyAddress: event.to?.lowercased())
    case .inbound:
      return SignAndCounterparty(
        signedQuantity: magnitude, counterpartyAddress: event.from.lowercased())
    case .selfSend:
      return SignAndCounterparty(signedQuantity: magnitude, counterpartyAddress: nil)
    case .unrelated:
      return nil
    }
  }

  /// Resolves the leg's `Instrument`. For native transfers (`.external`,
  /// `.internal`) returns the chain's native instrument directly — no
  /// discovery round-trip needed. For ERC-20 transfers, defers to
  /// `CryptoTokenDiscoveryService` so concurrent build calls share the
  /// same in-flight `Task` per `(chainId, contractAddress)` key.
  private func resolveInstrument(
    event: AlchemyTransfer,
    context: BuildContext
  ) async throws -> Instrument {
    switch event.category {
    case .external, .internal:
      return context.chain.nativeInstrument
    case .erc20:
      let contract = event.rawContract.address
      let decimals = event.rawContract.decimalsValue ?? 18
      let symbol = event.asset ?? "TOKEN"
      let registration = try await context.discovery.resolveOrLoad(
        chain: context.chain,
        contractAddress: contract,
        symbol: symbol,
        name: symbol,
        decimals: decimals)
      return registration.instrument
    case .unknown:
      // Filtered by caller; preserve the path so the type-checker keeps
      // the switch exhaustive.
      throw WalletSyncError.providerMalformedResponse(stage: "resolveInstrument-unknown")
    }
  }

  /// Converts an integer-units token amount into a human-scaled
  /// `Decimal`. Returns `nil` when the underlying hex parse failed (the
  /// caller logs and skips).
  ///
  /// For native transfers Alchemy may omit `decimal` — we substitute the
  /// chain's native decimals so a dropped field doesn't lose the row.
  private func scaledQuantity(
    rawDecimalValue: Decimal?,
    decimalsValue: Int?,
    category: AlchemyTransferCategory,
    chain: ChainConfig
  ) -> Decimal? {
    guard let rawDecimalValue else { return nil }
    let decimals: Int
    switch category {
    case .external, .internal:
      decimals = decimalsValue ?? chain.nativeInstrument.decimals
    case .erc20:
      // ERC-20 with no decimals reported is essentially uninterpretable —
      // refuse rather than guess.
      guard let decimalsValue else { return nil }
      decimals = decimalsValue
    case .unknown:
      return nil
    }
    guard decimals >= 0 else { return nil }
    return rawDecimalValue / Decimal(sign: .plus, exponent: decimals, significand: 1)
  }

}

/// Result of mapping a transfer's direction onto a leg's sign + the
/// other-party address.
private struct SignAndCounterparty {
  let signedQuantity: Decimal
  let counterpartyAddress: String?
}
