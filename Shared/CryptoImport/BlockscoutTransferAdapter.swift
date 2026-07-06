// Shared/CryptoImport/BlockscoutTransferAdapter.swift
import Foundation
import OSLog

/// One signed transaction the wallet paid gas for, with the block
/// timestamp needed to date a gas-only transaction (one with no value
/// transfer of its own — `approve()`, failed, zero-movement) and the
/// block number the windowed sync runner partitions on. This is the
/// authoritative gas set that fixes #919: it includes every tx where
/// the wallet is the sender, regardless of value or status.
///
/// `blockNumber` lets `WalletSyncWindowMath.partition` slice the signed
/// set per window exactly like the native rows. A signed tx and the
/// transfer event it pays gas for always share the same block (they are
/// the same on-chain transaction), so partitioning both by block keeps
/// the gas-only-synthesis and gas-leg paths inside a single window —
/// without it, the whole signed set was replayed into every window,
/// synthesising a phantom gas-only transaction in an earlier window
/// whose `"<hash>:gas"` leg then deduped the real transfer's gas leg
/// out on a later window.
struct SignedGasTx: Sendable, Hashable {
  let hash: String
  let blockTimestamp: Date
  let blockNumber: UInt64
}

/// Result of normalising Blockscout rows into the existing pipeline
/// model.
struct BlockscoutAdaptResult: Sendable {
  let transfers: [AlchemyTransfer]
  let signedGasTxs: [SignedGasTx]
}

/// Pure adapter: Blockscout native + internal rows → `AlchemyTransfer`s
/// (Alchemy-format `uniqueId`s so cross-account merge / per-leg dedup /
/// `externalId` indexing are reused unchanged) plus the signed-tx set.
/// Stateless and `Sendable`.
enum BlockscoutTransferAdapter {
  private static let logger = Logger(
    subsystem: "com.moolah.app", category: "BlockscoutTransferAdapter")

  /// `walletAddress` is expected pre-lowercased by the caller
  /// (`WalletSyncEngine` passes `account.walletAddress.lowercased()`),
  /// but every comparison re-lowercases defensively — Blockscout
  /// returns checksummed addresses.
  static func adapt(
    nativeTxs: [BlockscoutTransaction],
    internalTxs: [BlockscoutInternalTx],
    walletAddress rawWallet: String
  ) -> BlockscoutAdaptResult {
    let wallet = rawWallet.lowercased()
    var transfers: [AlchemyTransfer] = []
    var signed: [SignedGasTx] = []
    var seenSignedHashes: Set<String> = []

    for nativeTx in nativeTxs {
      let from = nativeTx.from.hash.lowercased()
      let to = nativeTx.to?.hash.lowercased()
      // Authoritative gas set: every tx the wallet signed, regardless
      // of value / status (#919). Dedup by hash, preserve first-seen.
      if from == wallet, seenSignedHashes.insert(nativeTx.hash).inserted {
        signed.append(
          SignedGasTx(
            hash: nativeTx.hash,
            blockTimestamp: parseTimestamp(nativeTx.timestamp) ?? Date(timeIntervalSince1970: 0),
            // `.magnitude` mirrors `makeTransfer`'s blockNum encoding —
            // Blockscout block numbers are non-negative, so this is a
            // total conversion into the `UInt64` the window math uses.
            blockNumber: UInt64(nativeTx.blockNumber.magnitude)))
      }
      // Value leg only for successful, non-zero transfers that touch the wallet.
      // Failed/reverted txs still paid gas (above) but did not move value.
      guard nativeTx.isSuccess else { continue }
      guard let weiHex = decimalStringToHexWei(nativeTx.value), weiHex != "0x0" else { continue }
      guard from == wallet || to == wallet else { continue }
      transfers.append(
        makeTransfer(
          identity: TransferIdentity(
            hash: nativeTx.hash,
            uniqueId: "\(nativeTx.hash):external:0",
            category: .external,
            from: nativeTx.from.hash,
            to: nativeTx.to?.hash),
          weiHex: weiHex,
          block: nativeTx.blockNumber,
          timestamp: nativeTx.timestamp))
    }

    for internalTx in internalTxs {
      let from = internalTx.from.hash.lowercased()
      let to = internalTx.to?.hash.lowercased()
      // Failed internal calls did not move value; drop them.
      guard internalTx.success else { continue }
      guard let weiHex = decimalStringToHexWei(internalTx.value), weiHex != "0x0" else { continue }
      guard from == wallet || to == wallet else { continue }
      transfers.append(
        makeTransfer(
          identity: TransferIdentity(
            hash: internalTx.transactionHash,
            uniqueId: "\(internalTx.transactionHash):internal:\(internalTx.index)",
            category: .internal,
            from: internalTx.from.hash,
            to: internalTx.to?.hash),
          weiHex: weiHex,
          block: internalTx.blockNumber,
          timestamp: internalTx.timestamp))
    }

    return BlockscoutAdaptResult(transfers: transfers, signedGasTxs: signed)
  }

  // MARK: - Internals

  // Identity fields of a Blockscout transfer event — the tx hash, Alchemy-format uniqueId,
  // category, and from/to counterparties — held separately from the transfer's value and
  // block-location fields.
  private struct TransferIdentity {
    let hash: String
    let uniqueId: String
    let category: AlchemyTransferCategory
    let from: String
    let to: String?
  }

  private static func makeTransfer(
    identity: TransferIdentity,
    weiHex: String,
    block: Int,
    timestamp: String?
  ) -> AlchemyTransfer {
    AlchemyTransfer(
      hash: identity.hash,
      uniqueId: identity.uniqueId,
      from: identity.from,
      to: identity.to,
      category: identity.category,
      asset: nil,
      rawContract: AlchemyTransfer.RawContract(
        address: nil, decimal: nil, rawValue: weiHex),
      metadata: AlchemyTransfer.Metadata(blockTimestamp: timestamp),
      blockNum: "0x" + String(UInt64(block.magnitude), radix: 16))
  }

  /// Blockscout `value` is a base-10 wei string. The builder consumes a
  /// `0x`-hex `rawValue` (`HexDecimal.parse`), so convert. Returns
  /// `"0x0"` for "0"; `nil` on non-numeric input (row logged + skipped).
  ///
  /// `internal` (not `private`) so `BlockscoutTransferAdapterTests` can
  /// exercise the base-10-wei → hex arithmetic in isolation — this
  /// project has a known `Decimal → Int64` truncation footgun, so the
  /// conversion is tested directly rather than only through the adapter.
  static func decimalStringToHexWei(_ decimalString: String) -> String? {
    let trimmed = decimalString.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber) else {
      logger.notice(
        "Skipping Blockscout row — non-numeric value: \(decimalString, privacy: .private)")
      return nil
    }
    if trimmed.allSatisfy({ $0 == "0" }) { return "0x0" }
    var value = Decimal(string: trimmed) ?? 0
    guard value > 0 else { return "0x0" }
    var digits = ""
    let sixteen = Decimal(16)
    while value > 0 {
      let remainder = value - decimalFloor(value / sixteen) * sixteen
      let nibble = (remainder as NSDecimalNumber).intValue
      digits.append(Self.hexDigits[nibble])
      value = decimalFloor(value / sixteen)
    }
    return "0x" + String(digits.reversed())
  }

  private static let hexDigits = Array("0123456789abcdef")

  /// Returns `value` rounded toward negative infinity (floor) to an
  /// integer. `Decimal` has no stdlib rounding (it isn't `FloatingPoint`);
  /// `NSDecimalRound(.down)` is the correct Foundation call. Used by the
  /// base-10-wei → hex loop, which needs exact integer division.
  private static func decimalFloor(_ value: Decimal) -> Decimal {
    var input = value
    var result = Decimal()
    NSDecimalRound(&result, &input, 0, .down)
    return result
  }

  /// ISO-8601 (Blockscout uses fractional seconds, e.g.
  /// `2024-09-12T12:34:56.000000Z`). Reuses the lenient policy: `nil`
  /// on unparseable input so a bad row degrades rather than fails.
  private static func parseTimestamp(_ raw: String?) -> Date? {
    guard let raw else { return nil }
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFraction.date(from: raw) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: raw)
  }
}
