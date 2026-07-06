// Shared/CryptoImport/WalletSyncWindowMath.swift
import Foundation

/// One inclusive block window `[from, to]` the windowed sync runner scans,
/// applies, and checkpoints as a unit. `to` is the block the apply pass
/// records on `WalletSyncState` / the synced checkpoint, so an interrupted
/// scan resumes from the last completed window's `to` (minus the reorg
/// window) rather than the top of the range.
struct WalletSyncWindow: Sendable, Equatable {
  let from: UInt64
  let to: UInt64
}

/// Pure arithmetic for the windowed direct-RPC sync runner: how to slice a
/// `[from, head]` block range into scan windows, which pre-fetched native
/// rows belong to a given window, and how far through the range a given
/// block sits (for determinate progress).
///
/// Split out from `WindowedWalletSyncRunner` as free functions so the
/// boundary arithmetic — single-block windows, exact multiples, `from >
/// head`, unparseable block numbers, fraction clamps — is testable without
/// any I/O or actor plumbing.
enum WalletSyncWindowMath {
  /// Inclusive windows covering `[from, head]` in steps of at most `size`
  /// blocks. Each window is `[start, min(start + size - 1, head)]`, so a
  /// window spans `size` blocks and the final window ends exactly on
  /// `head`. Returns an empty array when `from > head` (nothing to scan)
  /// and a single `[from, from]` window when `from == head`.
  ///
  /// `size` is assumed positive; a `size` of 0 would not advance and is a
  /// programmer error at the call site (the runner injects a fixed
  /// positive `segmentBlockWindow`).
  static func windows(from: UInt64, head: UInt64, size: UInt64) -> [WalletSyncWindow] {
    guard from <= head, size > 0 else { return [] }
    var result: [WalletSyncWindow] = []
    var start = from
    while start <= head {
      // `size - 1` because the window is inclusive on both ends: a window
      // starting at `start` and spanning `size` blocks ends at
      // `start + size - 1`. Guard the add against `UInt64` overflow near
      // the top of the range — `head` is the natural clamp anyway.
      let tentativeEnd = start.addingReportingOverflow(size - 1)
      let end = tentativeEnd.overflow ? head : Swift.min(tentativeEnd.partialValue, head)
      result.append(WalletSyncWindow(from: start, to: end))
      // Stop before `start` wraps past `UInt64.max` when the final window
      // already reached `head`.
      if end == head { break }
      start = end + 1
    }
    return result
  }

  /// The subset of `rows` whose parsed `blockNum` falls in
  /// `[window.from, window.to]`. The caller fetches the native context once
  /// for the whole range and partitions it per window with this.
  ///
  /// A row whose `blockNum` can't be parsed is dropped only so this stays a
  /// total function over any `[AlchemyTransfer]` — it is NOT a meaningful
  /// defensive filter here: the native rows this partitions are built by
  /// `BlockscoutTransferAdapter`, which synthesises `blockNum` from a typed
  /// integer (`"0x" + String(block, radix: 16)`), so every row is
  /// guaranteed parseable and no row is ever actually dropped. (This
  /// differs from `WalletSyncEngine.maxBlockNumber`, where the same parse
  /// rule guards a watermark against a genuinely provider-sourced string.)
  /// If a future wire-format change ever fed unparseable native rows in,
  /// they'd be excluded silently — the single-shot `build` path would
  /// instead surface that as the "builder dropped all transfers" warning.
  static func partition(
    _ rows: [AlchemyTransfer], into window: WalletSyncWindow
  ) -> [AlchemyTransfer] {
    rows.filter { row in
      guard let block = RPCHex.parseUInt64(row.blockNum) else { return false }
      return block >= window.from && block <= window.to
    }
  }

  /// The subset of `signedGasTxs` whose `blockNumber` falls in
  /// `[window.from, window.to]`. Mirrors the `[AlchemyTransfer]` overload
  /// so the signed-gas set is sliced per window exactly like the native
  /// rows: a signed tx and the transfer event it pays gas for share the
  /// same block, so partitioning both keeps gas-only synthesis and gas-leg
  /// attribution inside a single window. Passing the whole set to every
  /// window instead synthesised a phantom gas-only transaction in an
  /// earlier window whose `"<hash>:gas"` leg then deduped the real
  /// transfer's gas leg out of its own later window.
  static func partition(
    _ signedGasTxs: [SignedGasTx], into window: WalletSyncWindow
  ) -> [SignedGasTx] {
    signedGasTxs.filter { $0.blockNumber >= window.from && $0.blockNumber <= window.to }
  }

  /// The fraction of the `[from, head]` range that `pos` has reached,
  /// clamped to `0...1`. Returns `1.0` when `head == from` (a zero-width
  /// range is, by definition, already complete). Used to publish
  /// determinate `.scanning(fraction:)` progress as each window retires.
  static func fraction(pos: UInt64, from: UInt64, head: UInt64) -> Double {
    guard head > from else { return 1.0 }
    let span = Double(head - from)
    // Clamp `pos` into the range before differencing so the `UInt64`
    // subtraction can't underflow when `pos < from`.
    let clampedPos = Swift.min(Swift.max(pos, from), head)
    return Double(clampedPos - from) / span
  }
}
