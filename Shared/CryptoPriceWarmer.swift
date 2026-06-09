import Foundation
import OSLog

/// Background-fills historical crypto prices for a freshly-synced wallet,
/// automatically handling provider throttling: when a token's
/// `warmRange` reports a `RateLimitGateError.cooldown`, the warmer sleeps
/// until the deadline and retries that token, sleeping out at most
/// `maxCooldownCycles` cooldown gaps before leaving the rest for the next
/// sync. Tokens are processed serially so the shared per-host rate-limit
/// gate is not re-burst. This is best-effort background work: errors are
/// swallowed (logged); cancellation propagates. See issue #1075.
actor CryptoPriceWarmer {
  private let priceService: CryptoPriceService
  private let registrations: @Sendable () async throws -> [CryptoRegistration]
  private let now: @Sendable () -> Date
  private let sleep: @Sendable (Duration) async throws -> Void
  private let maxCooldownCycles: Int
  private let logger = Logger(subsystem: "com.moolah.app", category: "CryptoPriceWarmer")

  init(
    priceService: CryptoPriceService,
    registrations: @Sendable @escaping () async throws -> [CryptoRegistration],
    now: @Sendable @escaping () -> Date = { Date() },
    sleep: @Sendable @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    maxCooldownCycles: Int = 3
  ) {
    self.priceService = priceService
    self.registrations = registrations
    self.now = now
    self.sleep = sleep
    self.maxCooldownCycles = max(1, maxCooldownCycles)
  }

  /// Warm every priced crypto token appearing on `accountIds`' legs in
  /// `transactions`, over `[earliest leg date … now]` per token. Errors
  /// are swallowed (best-effort, background) — cancellation propagates.
  func warm(transactions: [Transaction], accountIds: Set<UUID>) async {
    let ranges = holdingRanges(transactions: transactions, accountIds: accountIds)
    guard !ranges.isEmpty else { return }
    let registrationsById: [String: CryptoRegistration]
    do {
      registrationsById = Dictionary(
        (try await registrations()).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    } catch {
      logger.warning(
        "warm: registration lookup failed: \(error.localizedDescription, privacy: .public)")
      return
    }
    for (instrumentId, range) in ranges {
      guard !Task.isCancelled else { return }
      guard let registration = registrationsById[instrumentId],
        registration.pricingStatus == .priced
      else { continue }
      await warmToken(registration: registration, range: range)
    }
  }

  /// Warm one token, sleeping out cooldown deadlines and retrying. The
  /// provider is given `maxCooldownCycles` chances after a cooldown: each
  /// cooldown sleeps until its deadline then retries; once that budget is
  /// exhausted the remaining gap is left for the next sync.
  private func warmToken(registration: CryptoRegistration, range: ClosedRange<Date>) async {
    var cooldownsWaited = 0
    while !Task.isCancelled {
      let outcome = await priceService.warmRange(
        for: registration.instrument, mapping: registration.mapping, in: range)
      guard !Task.isCancelled else { return }
      switch outcome {
      case .filled, .unavailable:
        return
      case .cooledDown(let until):
        guard cooldownsWaited < maxCooldownCycles else {
          logger.notice(
            "warm: giving up on \(registration.id, privacy: .public) after \(cooldownsWaited) cooldown cycles"
          )
          return
        }
        cooldownsWaited += 1
        let seconds = max(0, until.timeIntervalSince(now()))
        do {
          try await sleep(.seconds(seconds))
        } catch {
          return  // cancelled
        }
      }
    }
  }

  /// Earliest leg date per crypto instrument across `accountIds`' legs,
  /// paired with `now` as the upper bound.
  private func holdingRanges(
    transactions: [Transaction], accountIds: Set<UUID>
  ) -> [String: ClosedRange<Date>] {
    var earliest: [String: Date] = [:]
    for txn in transactions {
      for leg in txn.legs where leg.instrument.kind == .cryptoToken {
        guard let accountId = leg.accountId, accountIds.contains(accountId) else { continue }
        let id = leg.instrument.id
        earliest[id] = min(earliest[id] ?? txn.date, txn.date)
      }
    }
    let upper = now()
    var ranges: [String: ClosedRange<Date>] = [:]
    for (id, start) in earliest where start <= upper {
      ranges[id] = start...upper
    }
    return ranges
  }
}

/// Abstraction over `CryptoPriceWarmer` so `SyncedAccountStore` can be
/// tested with a spy. See issue #1075.
protocol PriceWarming: Sendable {
  func warm(transactions: [Transaction], accountIds: Set<UUID>) async
}

extension CryptoPriceWarmer: PriceWarming {}
