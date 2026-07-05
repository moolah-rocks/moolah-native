// Shared/CryptoImport/DirectRPC/AdaptiveLogRangeBatcher.swift
import Foundation

/// Walks a block range in chunks, adaptively shrinking the chunk size on
/// failure and growing it back on success.
///
/// Modelled on ConsenSys **Teku**'s `powchain` deposit-log fetching (see the
/// [post-incident review](https://github.com/ConsenSys/teku/wiki/Post-Incident-Review---Deposit-Processing-Performance)):
/// treat *every* failure from `fetch` — an explicit range-limit error, an
/// unrecognised provider error, or a plain timeout — as "the range was too
/// large" and retry the same starting point with a smaller chunk. This
/// deliberately does **not** try to string-match provider error messages;
/// they are inconsistent across nodes (message text, `-32xxx` codes, or bare
/// timeouts), so any failure is treated identically.
///
/// `CancellationError` is the one exception: it means the caller asked to
/// stop, not that the range was too large, so it is rethrown immediately
/// without halving or retrying.
struct AdaptiveLogRangeBatcher: Sendable {
  private let maxRange: UInt64
  private let minRange: UInt64

  /// - Parameters:
  ///   - maxRange: The chunk width `run` starts at and grows back toward
  ///     after a run of successes. Defaults to `10_000`, a conservative
  ///     starting point for `eth_getLogs`-style range caps.
  ///   - minRange: The floor a chunk is halved down to before a persistent
  ///     failure is allowed to propagate. Defaults to `1` (a single block).
  init(maxRange: UInt64 = 10_000, minRange: UInt64 = 1) {
    precondition(maxRange >= 1, "AdaptiveLogRangeBatcher requires a positive maxRange")
    precondition(minRange >= 1, "AdaptiveLogRangeBatcher requires a positive minRange")
    precondition(
      minRange <= maxRange,
      "AdaptiveLogRangeBatcher requires minRange <= maxRange"
    )
    self.maxRange = maxRange
    self.minRange = minRange
  }

  /// Walks `[from, to]` inclusive, calling `fetch(chunkFrom, chunkTo)` once
  /// per chunk, and returns the concatenated results in ascending block
  /// order.
  ///
  /// On any error thrown by `fetch` (other than `CancellationError`), the
  /// current chunk width is halved (floored at `minRange`) and the same
  /// starting block is retried with the smaller chunk. After a successful
  /// fetch the chunk width is grown back — doubled, capped at `maxRange` —
  /// so a transient failure does not permanently shrink every subsequent
  /// request. If `fetch` still throws once the chunk width has already
  /// reached `minRange`, the error is a genuine per-request failure rather
  /// than a range problem, and it propagates to the caller.
  func run<T: Sendable>(
    from: UInt64,
    to: UInt64,
    fetch: @Sendable (UInt64, UInt64) async throws -> [T]
  ) async throws -> [T] {
    guard from <= to else { return [] }

    var results: [T] = []
    var position = from
    var currentSpan = maxRange

    while true {
      // Explicit per-iteration cancellation check — a URLSession fetch
      // cancels as URLError(.cancelled), not CancellationError, so don't
      // rely on the catch arm.
      try Task.checkCancellation()
      let chunkTo = chunkEnd(from: position, span: currentSpan, upperBound: to)
      do {
        let chunkResults = try await fetch(position, chunkTo)
        results.append(contentsOf: chunkResults)
        currentSpan = grown(currentSpan)
        guard chunkTo < to else { break }
        position = chunkTo + 1
      } catch let cancellation as CancellationError {
        throw cancellation
      } catch {
        guard currentSpan > minRange else { throw error }
        currentSpan = max(minRange, currentSpan / 2)
      }
    }
    return results
  }

  /// The inclusive end of a chunk starting at `from` with width `span`,
  /// clamped to `upperBound` and guarded against overflow when `from` is
  /// already close to `UInt64.max`.
  private func chunkEnd(from: UInt64, span: UInt64, upperBound: UInt64) -> UInt64 {
    let (sum, overflowed) = from.addingReportingOverflow(span - 1)
    if overflowed { return upperBound }
    return min(sum, upperBound)
  }

  /// Doubles `span`, capped at `maxRange`, guarding against overflow for a
  /// very large `maxRange`.
  private func grown(_ span: UInt64) -> UInt64 {
    guard span < maxRange else { return maxRange }
    let (doubled, overflowed) = span.multipliedReportingOverflow(by: 2)
    if overflowed { return maxRange }
    return min(maxRange, doubled)
  }
}
