// Shared/CryptoImport/TransferReceiptCoalescer.swift
import Foundation
import OSLog

/// Receipt coalescing + gas-leg construction helpers for
/// `TransferEventBuilder`. Module-internal — only the builder calls
/// these. All functions are `Sendable`-pure (no captured state) so
/// they're safe to call from inside the parallel build path.
enum TransferReceiptCoalescer {
  /// Shared static `Logger`; matches the builder's pattern so receipt
  /// failures appear under the same subsystem in Console.app.
  private static let logger = Logger(
    subsystem: "com.moolah.app", category: "TransferEventBuilder")

  /// Fetches `eth_getTransactionReceipt` for every unique outbound
  /// transfer hash in `groups`, in parallel via a `TaskGroup`. Coalescing
  /// happens at the hash level: a transaction with N outbound transfer
  /// legs (e.g. a multi-token swap) triggers exactly one receipt fetch.
  /// Inbound-only events don't trigger fetches — gas-leg construction
  /// is restricted to the from-side wallet per the design's "from-side
  /// wallet only" rule.
  ///
  /// `extraSignedHashes` extends the fetch set with hashes for signed
  /// transactions that produced no transfer events (e.g. `approve()`,
  /// failed txs); deduplicated against and appended after the outbound
  /// hashes from `groups`, preserving order.
  ///
  /// Per-receipt fetch failures (network blip, rate limit on a single
  /// hash, malformed response) log and are dropped from the returned
  /// dictionary; affected events ship without a gas leg. This keeps a
  /// single bad receipt from failing the whole account, mirroring the
  /// builder's per-row decode-failure policy elsewhere. Cancellation is
  /// re-thrown so the group cancels every sibling and the caller sees
  /// the cancellation rather than a missing leg.
  static func fetchReceipts(
    groups: [[AlchemyTransfer]],
    extraSignedHashes: [String] = [],
    walletAddress: String,
    chain: ChainConfig,
    alchemy: any ChainDataClient
  ) async throws -> [String: AlchemyTransactionReceipt] {
    var hashes = outboundHashes(in: groups, walletAddress: walletAddress)
    var seen = Set(hashes)
    for hash in extraSignedHashes where seen.insert(hash).inserted {
      hashes.append(hash)
    }
    guard !hashes.isEmpty else { return [:] }
    var receipts: [String: AlchemyTransactionReceipt] = [:]
    receipts.reserveCapacity(hashes.count)
    try await withThrowingTaskGroup(of: AlchemyTransactionReceipt?.self) { group in
      for hash in hashes {
        group.addTask {
          try await fetchOne(hash: hash, chain: chain, alchemy: alchemy)
        }
      }
      for try await maybeReceipt in group {
        if let receipt = maybeReceipt {
          receipts[receipt.hash] = receipt
        }
      }
    }
    return receipts
  }

  /// Single-hash receipt fetch with the per-hash error-containment
  /// policy. `CancellationError` re-throws so the enclosing `TaskGroup`
  /// (and the outer build) terminate cleanly; every other failure logs
  /// and returns `nil` so the affected event ships without a gas leg.
  /// This keeps a transient receipt failure from blocking the rest of
  /// the account's sync.
  private static func fetchOne(
    hash: String,
    chain: ChainConfig,
    alchemy: any ChainDataClient
  ) async throws -> AlchemyTransactionReceipt? {
    do {
      return try await alchemy.getTransactionReceipt(chain: chain, hash: hash)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      logger.notice(
        "Skipping gas leg for hash \(hash, privacy: .private) — receipt fetch failed: \(error.localizedDescription, privacy: .public)"
      )
      return nil
    }
  }

  /// Walks the grouped transfers and returns the set of `txHash` values
  /// for which we need to fetch the receipt to decide gas attribution.
  /// The authoritative gate (`receipt.from == walletAddress`) lives in
  /// `makeGasLeg`; this predicate is just the cheap pre-filter that
  /// avoids a network round-trip for hashes we can already prove the
  /// wallet didn't sign.
  ///
  /// A hash is eligible when any non-NFT event in the group either:
  ///
  /// - has `from == walletAddress` — the wallet may be the signer
  ///   (`.external`), or appears as the token-sender row of a contract
  ///   call (`.erc20` / `.internal`), and we can't tell from the
  ///   transfer alone whether the wallet itself or a third-party router
  ///   signed; or
  /// - has any non-`.external` category, regardless of direction —
  ///   `.erc20` and `.internal` rows can come from a contract call the
  ///   wallet signed even when every transfer event has the wallet as
  ///   `to` (a mint, claim, or contract-buy). `.external` is the only
  ///   category that's always a top-level call: its `from` is the EOA,
  ///   so an `.external` row with `from != walletAddress` proves the
  ///   wallet didn't sign and a receipt fetch is unnecessary.
  ///
  /// NFT (`unknown`) categories are filtered out — gas-leg attribution
  /// is only meaningful for accepted categories.
  ///
  /// The walk preserves first-seen order so receipt fetches retire in a
  /// deterministic sequence (helps with signpost tracing).
  static func outboundHashes(
    in groups: [[AlchemyTransfer]],
    walletAddress: String
  ) -> [String] {
    var seen: Set<String> = []
    var ordered: [String] = []
    for events in groups {
      guard let first = events.first else { continue }
      let needsReceipt = events.contains { event in
        guard event.category != .unknown else { return false }
        if event.from.lowercased() == walletAddress { return true }
        return event.category != .external
      }
      guard needsReceipt, seen.insert(first.hash).inserted else { continue }
      ordered.append(first.hash)
    }
    return ordered
  }

  /// Builds the gas leg for an outbound transaction from a fetched
  /// receipt. The leg is `.expense` typed, denominated in the chain's
  /// native instrument, and carries a negative quantity — gas is always
  /// paid out (this wallet is the signer of the outer tx). Per the
  /// project sign rule (CLAUDE.md "Monetary Sign Convention") the
  /// negative is preserved rather than `abs()`-stripped; downstream
  /// display logic handles the sign.
  ///
  /// On OP-stack chains (`chain.chargesL1DataFee`) the fee is the L2
  /// execution cost *plus* the L1 data fee (`receipt.l1FeeWei`), which
  /// is usually the dominant component. Both are summed before scaling
  /// so Optimism / Base gas isn't under-counted by ~an order of
  /// magnitude (#920). On Ethereum / Polygon the L1 component is `nil`
  /// and the fee is the L2 execution cost alone.
  ///
  /// If an OP-stack receipt arrives *without* `l1FeeWei` (the field
  /// should always be present there — a missing one indicates a
  /// provider/shape anomaly, not a free transaction), the leg is still
  /// built from the L2 portion alone rather than dropped: an
  /// under-counted gas leg is less wrong than silently losing the
  /// expense entirely. The anomaly is logged so the under-count is
  /// observable rather than silent.
  ///
  /// Returns `nil` in any of:
  /// - `receipt.from != walletAddress`: the wallet did not sign the
  ///   outer tx (e.g. an `internal` row where the wallet appears as a
  ///   sub-call's `from` inside someone else's tx, or an `erc20
  ///   transferFrom` initiated by a router holding approval). The
  ///   on-chain gas was paid by another EOA, not us.
  /// - total gas fee `<= 0`: zero-fee synthetic. A zero gas leg would
  ///   clutter the transaction without representing real expense.
  ///
  /// `walletAddress` is expected pre-lowercased (the builder passes
  /// `BuildContext.walletAddress`). `receipt.from` is also lowercased at
  /// the wire boundary in `AlchemyTransactionReceiptPayload.toReceipt`,
  /// but the comparison re-lowercases defensively — that mirrors
  /// `outboundHashes`'s defensive normalisation, and means a test stub or
  /// future caller that constructs `AlchemyTransactionReceipt` directly
  /// with a checksummed `from` doesn't silently miss a match.
  static func makeGasLeg(
    receipt: AlchemyTransactionReceipt,
    accountId: UUID,
    chain: ChainConfig,
    walletAddress: String
  ) -> TransactionLeg? {
    guard receipt.from.lowercased() == walletAddress else { return nil }
    let l1DataFeeWei: Decimal
    if chain.chargesL1DataFee {
      if let l1FeeWei = receipt.l1FeeWei {
        l1DataFeeWei = l1FeeWei
      } else {
        l1DataFeeWei = 0
        Self.logger.notice(
          "OP-stack receipt missing l1Fee for hash \(receipt.hash, privacy: .private) on chain \(chain.chainId, privacy: .public) — gas leg under-counts the L1 data fee (#920)"
        )
      }
    } else {
      l1DataFeeWei = 0
    }
    let gasFeeWei = receipt.l2ExecutionFeeWei + l1DataFeeWei
    guard gasFeeWei > 0 else { return nil }
    let nativeDecimals = chain.nativeInstrument.decimals
    guard nativeDecimals >= 0 else { return nil }
    let scale = Decimal(sign: .plus, exponent: nativeDecimals, significand: 1)
    let gasFeeNative = gasFeeWei / scale
    return TransactionLeg(
      accountId: accountId,
      instrument: chain.nativeInstrument,
      quantity: -gasFeeNative,
      externalId: Self.gasLegExternalId(hash: receipt.hash),
      type: .expense)
  }

  /// Builds the gas-leg's `externalId` from the transaction hash. The
  /// `":gas"` suffix is intentional — every transfer leg already uses
  /// Alchemy's `uniqueId` (`"<hash>:<category>:<index>"`), so the gas
  /// leg needs its own tag to share the namespace without colliding
  /// on the schema's partial unique index `(accountId, externalId)`.
  /// Exposed so the deduper / merger tests can build the same string
  /// without re-deriving the format.
  static func gasLegExternalId(hash: String) -> String {
    "\(hash):gas"
  }
}
