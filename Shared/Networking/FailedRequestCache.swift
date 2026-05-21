import Foundation

/// Thrown by `RateLimitedHTTPClient.data(for:)` when a recently-failed
/// request is repeated before its cooldown expires. The `until` payload
/// is the deadline after which the same request will be allowed through
/// again.
enum FailedRequestCacheError: Error, Equatable {
  case cooldown(until: Date)
}

/// Per-URL cooldown so a request that just failed isn't re-issued in a
/// hot loop.
///
/// Complements `RateLimitGate`: the gate is host-wide and trips only on
/// `429` / `418` / `503-Retry-After` (so other URLs to the same host
/// keep working); this cache is per-URL and trips on **any** failure
/// (so a different URL to the same host is unaffected). Together they
/// handle the two common "spam loop" shapes:
///
/// - The host has rate-limited us → host-wide gate → fall through to
///   the next provider in the price-service chain.
/// - A specific resource keeps failing (deleted ticker, unknown coin,
///   network blip) → per-URL cache → that one provider stops probing
///   for that one resource until the cooldown lapses.
///
/// **Two failure modes, two cadences.** HTTP failures (`4xx` / `5xx`
/// responses from the server) get a fixed cooldown — if the server
/// says "no" once, it'll probably say "no" for a while, so the wait is
/// long enough to break a refresh loop but short enough that a user
/// fixing a typo still sees a fresh attempt. Transport failures (DNS,
/// offline, timeout, server hangup) get **per-URL exponential backoff
/// capped at 2 minutes** instead — the network coming back is a
/// matter of seconds, not minutes, so the first retry is fast and
/// only a sustained outage drags out the wait.
///
/// Concurrency: actor. The internal map is bounded by `maxEntries`;
/// when full, expired entries are pruned in bulk before inserting a
/// new entry. There is no per-eviction LRU because the typical working
/// set (failing tickers / coin ids per session) is far below the
/// default ceiling.
actor FailedRequestCache {
  private struct Entry {
    var deadline: Date
    /// Number of consecutive transport failures recorded for this URL.
    /// Used to compute the next exponential backoff. Reset to 0 on
    /// `recordHTTPFailure` (the host responded — transport is fine)
    /// and on `recordSuccess` (entry removed entirely).
    var consecutiveTransportFailures: Int
  }

  private let httpCooldownDuration: TimeInterval
  private let transportBaseBackoff: TimeInterval
  private let transportMaxBackoff: TimeInterval
  private let maxEntries: Int
  private let now: @Sendable () -> Date
  private var entries: [String: Entry] = [:]

  /// - Parameters:
  ///   - httpCooldownDuration: How long a `4xx` / `5xx` response keeps
  ///     a URL muted. Defaults to 5 minutes — long enough that a
  ///     chart redraw / live price tick won't re-probe immediately,
  ///     short enough that a user fixing a typo and resubmitting
  ///     still sees a fresh attempt.
  ///   - transportBaseBackoff: First-failure backoff for transport
  ///     errors. Defaults to 5 seconds — short enough that a
  ///     transient blip clears almost immediately on the user's next
  ///     interaction.
  ///   - transportMaxBackoff: Ceiling for transport-error backoff.
  ///     Defaults to 2 minutes — beyond this the user is going to
  ///     retry manually anyway.
  ///   - maxEntries: Soft cap on the cache size. When exceeded,
  ///     expired entries are pruned; if all entries are still active,
  ///     the new entry replaces the oldest deadline. Defaults to 256.
  ///   - now: Closure returning the current time. Defaults to `Date()`.
  init(
    httpCooldownDuration: TimeInterval = 300,
    transportBaseBackoff: TimeInterval = 5,
    transportMaxBackoff: TimeInterval = 120,
    maxEntries: Int = 256,
    now: @Sendable @escaping () -> Date = { Date() }
  ) {
    self.httpCooldownDuration = httpCooldownDuration
    self.transportBaseBackoff = transportBaseBackoff
    self.transportMaxBackoff = transportMaxBackoff
    self.maxEntries = maxEntries
    self.now = now
  }

  /// Throws `FailedRequestCacheError.cooldown(until:)` when `key` is
  /// still within its failure window. As a side effect, clears an
  /// expired entry so the next call goes through cleanly.
  func ensureAvailable(for key: String) throws {
    guard let entry = entries[key] else { return }
    if now() < entry.deadline {
      throw FailedRequestCacheError.cooldown(until: entry.deadline)
    }
    entries.removeValue(forKey: key)
  }

  /// Drops `key`'s entry — both the deadline and the transport
  /// failure counter. Called after a 2xx so a transient failure
  /// doesn't outlive the recovery.
  func recordSuccess(for key: String) {
    entries.removeValue(forKey: key)
  }

  /// Records an HTTP-level failure (4xx / 5xx) for `key`. Uses a fixed
  /// cooldown — if the server has explicitly said "no", a brief wait
  /// and an immediate retry are equally likely to produce the same
  /// "no", so polling sooner doesn't help.
  ///
  /// Resets the transport failure counter on the assumption that the
  /// host responding at all means the network path is healthy.
  @discardableResult
  func recordHTTPFailure(for key: String) -> Date {
    boundIfNeeded()
    let deadline = now().addingTimeInterval(httpCooldownDuration)
    entries[key] = Entry(deadline: deadline, consecutiveTransportFailures: 0)
    return deadline
  }

  /// Records a transport-level failure (DNS, offline, timeout) for
  /// `key`. Uses **per-URL exponential backoff** — `base * 2^(n-1)`,
  /// capped at `transportMaxBackoff`. The first retry is fast (a
  /// transient connectivity blip clears in seconds) and the wait
  /// only grows when the outage is sustained.
  @discardableResult
  func recordTransportFailure(for key: String) -> Date {
    boundIfNeeded()
    let consecutive = (entries[key]?.consecutiveTransportFailures ?? 0) + 1
    // 5s, 10s, 20s, ..., capped at `transportMaxBackoff`. `pow` on
    // `Double` is total — overflow saturates to `.infinity`, which
    // `min(_:_:)` collapses back to the cap.
    let exp = transportBaseBackoff * pow(2.0, Double(max(0, consecutive - 1)))
    let backoff = min(exp, transportMaxBackoff)
    let deadline = now().addingTimeInterval(backoff)
    entries[key] = Entry(deadline: deadline, consecutiveTransportFailures: consecutive)
    return deadline
  }

  private func boundIfNeeded() {
    guard entries.count >= maxEntries else { return }
    pruneExpired()
    if entries.count >= maxEntries {
      evictOldest()
    }
  }

  private func pruneExpired() {
    let currentTime = now()
    entries = entries.filter { $0.value.deadline > currentTime }
  }

  /// Removes the entry with the smallest deadline so the cache can
  /// accept a new entry under sustained-failure pressure. Picks one
  /// deterministically; a tie on deadline removes whichever
  /// `min(by:)` selects first, which is acceptable because both
  /// entries have identical staleness.
  private func evictOldest() {
    guard
      let oldestKey = entries.min(by: { $0.value.deadline < $1.value.deadline })?.key
    else { return }
    entries.removeValue(forKey: oldestKey)
  }
}
