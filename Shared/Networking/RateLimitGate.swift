import Foundation

/// Thrown by `RateLimitedHTTPClient.data(for:)` when the gate is in cooldown
/// or when the just-completed response was a rate-limit. The `until` payload
/// is the deadline after which the next request will be allowed through;
/// callers can surface it for diagnostics or schedule a retry, but the
/// standard pattern is to fall through to the next provider in a fallback
/// chain.
enum RateLimitGateError: Error, Equatable {
  case cooldown(until: Date)
}

/// Per-client cooldown gate that prevents repeated requests to a remote
/// API after it has rate-limited us.
///
/// Each upstream price client (CoinGecko, CryptoCompare, Binance, Yahoo
/// Finance, Frankfurter) owns one gate. On a `429` (or `418`, or `503`
/// carrying a `Retry-After` header) the gate is closed until a deadline:
/// either the value of `Retry-After` or — if absent — an exponential
/// backoff (`baseBackoff * 2^(failures-1)`, capped at `maxBackoff`).
/// While the gate is closed, `checkAvailable()` throws
/// `RateLimitGateError.cooldown(until:)` so the caller can fail fast and
/// fall through to a fallback provider rather than continuing to spam
/// the limited host. A successful response resets the failure count and
/// reopens the gate.
///
/// Concurrency: this is an `actor` so multiple Tasks racing to the same
/// upstream serialise through `checkAvailable` / `recordRateLimit` /
/// `recordSuccess`. The clock is injected via `now` so tests can pin
/// "current time" without relying on wall-clock progression.
actor RateLimitGate {
  private let baseBackoff: TimeInterval
  private let maxBackoff: TimeInterval
  private let now: @Sendable () -> Date
  private var blockedUntil: Date?
  private var consecutiveFailures: Int = 0

  /// - Parameters:
  ///   - baseBackoff: First-failure backoff when the server doesn't supply
  ///     `Retry-After`. Defaults to 30s — long enough that a free-tier
  ///     limiter (~30 req/min) can refill without a re-probe.
  ///   - maxBackoff: Ceiling for both `Retry-After` and exponential
  ///     backoff. Defaults to 10 minutes — beyond this the user is going
  ///     to retry manually anyway, and indefinite blocks risk masking a
  ///     mis-configured client (e.g. a permanently bad API key
  ///     responding with 429 forever).
  ///   - now: Closure returning the current time. Defaults to `Date()`.
  init(
    baseBackoff: TimeInterval = 30,
    maxBackoff: TimeInterval = 600,
    now: @Sendable @escaping () -> Date = { Date() }
  ) {
    self.baseBackoff = baseBackoff
    self.maxBackoff = maxBackoff
    self.now = now
  }

  /// Throws `RateLimitGateError.cooldown(until:)` when the gate is closed.
  /// As a side effect, clears an expired cooldown so the next request
  /// goes through cleanly.
  func ensureAvailable() throws {
    guard let deadline = blockedUntil else { return }
    if now() < deadline {
      throw RateLimitGateError.cooldown(until: deadline)
    }
    blockedUntil = nil
  }

  /// Marks the most recent call as successful. Resets failure tracking and
  /// clears any **expired** cooldown — but never tramples an active
  /// cooldown that a concurrent rate-limit response set after this call
  /// began. Without that guard, a Task that already passed
  /// `ensureAvailable` and won the race to a 200 would erase the
  /// cooldown a sibling Task's 429 just established, defeating the
  /// fail-fast contract for the next caller.
  func recordSuccess() {
    consecutiveFailures = 0
    if let deadline = blockedUntil, now() < deadline { return }
    blockedUntil = nil
  }

  /// Records a rate-limit response and computes the next cooldown deadline.
  /// `retryAfter` is the server-supplied `Retry-After` value in seconds (or
  /// `nil` when the header is absent / malformed). Returns the chosen
  /// deadline so callers can include it in the thrown error or log line.
  @discardableResult
  func recordRateLimit(retryAfter: TimeInterval? = nil) -> Date {
    consecutiveFailures += 1
    let backoff: TimeInterval
    if let retryAfter, retryAfter > 0 {
      backoff = min(retryAfter, maxBackoff)
    } else {
      // 30s, 60s, 120s, ..., capped at `maxBackoff`. `pow` on `Double`
      // is total — overflow saturates to `.infinity`, which `min(_:_:)`
      // collapses back to the cap.
      let exp = baseBackoff * pow(2.0, Double(max(0, consecutiveFailures - 1)))
      backoff = min(exp, maxBackoff)
    }
    let deadline = now().addingTimeInterval(backoff)
    blockedUntil = deadline
    return deadline
  }
}

extension HTTPURLResponse {
  /// Parses the `Retry-After` header into a non-negative `TimeInterval`.
  /// Supports both spec-defined forms: delta-seconds (e.g. `"120"`) and
  /// HTTP-date (e.g. `"Wed, 21 Oct 2015 07:28:00 GMT"`). Returns `nil`
  /// when the header is absent or malformed; clamps past dates to `0`.
  ///
  /// `now` is required (no default) so callers must thread their own
  /// clock through. The HTTP-date branch needs a reference point to
  /// compute relative seconds; the delta-seconds branch ignores `now`.
  func retryAfterSeconds(now: Date) -> TimeInterval? {
    guard let raw = value(forHTTPHeaderField: "Retry-After") else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let seconds = TimeInterval(trimmed), seconds >= 0 {
      return seconds
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
    if let date = formatter.date(from: trimmed) {
      return max(0, date.timeIntervalSince(now))
    }
    return nil
  }
}
