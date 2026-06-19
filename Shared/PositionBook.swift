import Foundation
import OSLog

private let logger = Logger(subsystem: "com.moolah.app", category: "PositionBook")

/// Per-entity, per-instrument position state. The single place where position
/// math for transactions and legs lives.
///
/// `PositionBook` is the canonical primitive used by both:
/// - `BalanceDeltaCalculator` (transaction create/update/delete deltas), and
/// - the analysis pipeline (daily balance accumulation across ranges).
///
/// All math is multi-instrument by construction: positions are tracked as raw
/// `Decimal` quantities keyed by `Instrument`. Conversion to a profile
/// instrument happens only at read time via `dailyBalance(...)`.
struct PositionBook: Equatable, Sendable {
  /// Per-account positions across all leg types.
  var accounts: [UUID: [Instrument: Decimal]] = [:]

  /// Per-earmark net position (sum of all leg quantities tagged with the
  /// earmark, signed as in the leg).
  var earmarks: [UUID: [Instrument: Decimal]] = [:]

  /// Per-earmark "saved" totals — sum of `.income`, `.openingBalance`, and `.trade` legs.
  /// Tracks the change to the saved-into-earmark total.
  var earmarksSaved: [UUID: [Instrument: Decimal]] = [:]

  /// Per-earmark "spent" totals — sum of `.expense` and `.transfer` legs,
  /// stored as positive quantities (i.e. negated against the leg quantity).
  /// Refunds (positive expense quantities) correctly reduce the spent total.
  var earmarksSpent: [UUID: [Instrument: Decimal]] = [:]

  /// Positions on investment accounts arising from `.transfer` legs only —
  /// used to compute the `investments` total under the
  /// `.investmentTransfersOnly` accumulation rule.
  ///
  /// Tracked in parallel with `accounts` so a single accumulator can serve both
  /// `.allLegs` (starting balance) and `.investmentTransfersOnly` (post-cutoff
  /// daily delta) reading rules without re-traversing transactions. For users
  /// with no investment accounts this dict stays empty.
  var accountsFromTransfers: [UUID: [Instrument: Decimal]] = [:]

  static let empty = PositionBook()

  // MARK: - Apply

  /// The canonical per-leg math. Mutates the four position dicts based on the
  /// leg's account/earmark membership and type, plus `accountsFromTransfers`
  /// when the leg targets an investment account via a `.transfer` (or, when
  /// `asStartingBalance` is true, any leg type on an investment account).
  ///
  /// Private — callers should drive position math through the txn-level
  /// `apply(_ txn:sign:investmentAccountIds:asStartingBalance:)` overload,
  /// which decides investment-account membership once per transaction and
  /// avoids leaking accumulator policy into the per-leg primitive.
  ///
  /// - Parameters:
  ///   - leg: The leg to apply.
  ///   - sign: +1 to apply the leg, -1 to reverse it (used by delta math).
  ///   - isInvestmentAccount: Whether `leg.accountId` corresponds to an
  ///     investment account. When true and the leg is a transfer (or
  ///     `asStartingBalance` is true), the leg also contributes to
  ///     `accountsFromTransfers`.
  ///   - asStartingBalance: When true, every leg on an investment account is
  ///     written into `accountsFromTransfers`, regardless of leg type. See
  ///     the public `apply` overload for the rationale.
  private mutating func apply(
    _ leg: TransactionLeg,
    sign: Decimal = 1,
    isInvestmentAccount: Bool = false,
    asStartingBalance: Bool = false
  ) {
    let quantity = leg.quantity

    if let accountId = leg.accountId {
      accounts[accountId, default: [:]][leg.instrument, default: 0] += sign * quantity

      if isInvestmentAccount && (asStartingBalance || leg.type == .transfer) {
        accountsFromTransfers[accountId, default: [:]][leg.instrument, default: 0] +=
          sign * quantity
      }
    }

    if let earmarkId = leg.earmarkId {
      earmarks[earmarkId, default: [:]][leg.instrument, default: 0] += sign * quantity

      switch leg.type {
      case .income, .openingBalance, .trade:
        // Saved tracks the change to the saved total. Income/openingBalance/trade
        // quantities are positive, so sign * quantity gives the right direction.
        earmarksSaved[earmarkId, default: [:]][leg.instrument, default: 0] += sign * quantity

      case .expense, .transfer:
        // Spent tracks the change to the spent total (stored as positive
        // quantities). Negate the leg quantity: expenses are typically negative
        // (outflows), so negating gives a positive spent amount. Refunds
        // (positive expense quantity) correctly reduce spent.
        earmarksSpent[earmarkId, default: [:]][leg.instrument, default: 0] += sign * (-quantity)
      }
    }
  }

  /// Apply (or reverse) every leg of `txn`. The caller supplies
  /// `investmentAccountIds` so that investment-account membership is decided
  /// once per transaction.
  ///
  /// - Parameter asStartingBalance: Pass `true` for transactions that predate
  ///   the analysis window (`date < after`). This ensures the
  ///   `.investmentTransfersOnly` read rule sees the historical position as a
  ///   baseline, matching the `investmentTransfersOnly: false` behaviour
  ///   for pre-`after` priors. Use `false` (the default) for transactions
  ///   inside the analysis window — only `.transfer` legs on investment
  ///   accounts contribute to the transfers-only view.
  ///
  /// - Note: Does NOT skip scheduled transactions — callers that need to
  ///   exclude scheduled flows must do so before calling.
  mutating func apply(
    _ txn: Transaction,
    sign: Decimal = 1,
    investmentAccountIds: Set<UUID> = [],
    asStartingBalance: Bool = false
  ) {
    for leg in txn.legs {
      let isInvestment = leg.accountId.map(investmentAccountIds.contains) ?? false
      apply(
        leg,
        sign: sign,
        isInvestmentAccount: isInvestment,
        asStartingBalance: asStartingBalance)
    }
  }

  /// Strip per-instrument entries whose value is exactly zero, and remove
  /// outer entity entries whose inner dict becomes empty. Applied to all five
  /// dicts. Match the cleanup `BalanceDeltaCalculator` performs before
  /// publishing deltas.
  mutating func cleanZeros() {
    Self.cleanZeros(&accounts)
    Self.cleanZeros(&earmarks)
    Self.cleanZeros(&earmarksSaved)
    Self.cleanZeros(&earmarksSpent)
    Self.cleanZeros(&accountsFromTransfers)
  }

  private static func cleanZeros(_ dict: inout [UUID: [Instrument: Decimal]]) {
    for (entityId, instruments) in dict {
      var cleaned = instruments
      for (instrument, value) in cleaned where value == 0 {
        cleaned.removeValue(forKey: instrument)
      }
      if cleaned.isEmpty {
        dict.removeValue(forKey: entityId)
      } else {
        dict[entityId] = cleaned
      }
    }
  }

  // MARK: - Daily Balance

  /// Determines how the `investments` total is computed from the book.
  enum AccumulationRule: Sendable {
    /// All positions on investment accounts contribute to `investments`.
    /// Use for starting-balance computations (pre-`after` cutoff).
    case allLegs
    /// Only positions arising from `.transfer` legs on investment accounts
    /// contribute to `investments`. Use for post-`after` daily balances.
    case investmentTransfersOnly
  }

  /// Per-pipeline inputs that stay constant across a sequence of
  /// `dailyBalance(on:context:isForecast:)` calls: which accounts are
  /// investments, the profile's instrument, the accumulation rule, and the
  /// conversion service. Grouping them into a struct hoists one
  /// allocation outside the per-day loop at each caller.
  struct BalanceContext {
    let investmentAccountIds: Set<UUID>
    let profileInstrument: Instrument
    let rule: AccumulationRule
    let conversionService: any InstrumentConversionService
  }

  /// Build a `DailyBalance` snapshot from the current book state, converting
  /// per-instrument positions to `profileInstrument` on `date`.
  ///
  /// Semantics:
  /// - `balance` sums positions in non-investment accounts.
  /// - `investments` sums positions in investment accounts under the chosen
  ///   `rule` (either all positions or only transfer-derived positions).
  /// - `earmarked` sums each earmark's positions converted to
  ///   `profileInstrument`, then clamps each per-earmark sum to `>= 0`
  ///   before adding to the overall total. Negative earmarks (e.g. those
  ///   funding investments) do not reduce the total.
  /// - `availableFunds = balance - earmarked`.
  /// - `netWorth = balance + investments`.
  /// - `investmentValue` and `bestFit` are left `nil`; callers fill them in.
  ///
  /// Single-instrument fast path: positions whose instrument equals
  /// `profileInstrument` skip the conversion service entirely.
  func dailyBalance(
    on date: Date,
    context: BalanceContext,
    isForecast: Bool
  ) async throws -> DailyBalance {
    let profileInstrument = context.profileInstrument
    let investmentAccountIds = context.investmentAccountIds
    let conversionService = context.conversionService

    // Bank balance: all non-investment account positions.
    var bankTotal: Decimal = 0
    for (accountId, positions) in accounts where !investmentAccountIds.contains(accountId) {
      bankTotal += try await convert(
        positions, to: profileInstrument, on: date, using: conversionService)
    }

    // Investments: depending on rule.
    var investmentsTotal: Decimal = 0
    switch context.rule {
    case .allLegs:
      for (accountId, positions) in accounts where investmentAccountIds.contains(accountId) {
        investmentsTotal += try await convert(
          positions, to: profileInstrument, on: date, using: conversionService)
      }
    case .investmentTransfersOnly:
      for (accountId, positions) in accountsFromTransfers
      where investmentAccountIds.contains(accountId) {
        investmentsTotal += try await convert(
          positions, to: profileInstrument, on: date, using: conversionService)
      }
    }

    // Earmarks: per-earmark sum, clamp each to >= 0, then total.
    var earmarkedTotal: Decimal = 0
    for (_, positions) in earmarks {
      let perEarmark = try await convert(
        positions, to: profileInstrument, on: date, using: conversionService)
      earmarkedTotal += max(perEarmark, 0)
    }

    let balance = InstrumentAmount(quantity: bankTotal, instrument: profileInstrument)
    let investments = InstrumentAmount(quantity: investmentsTotal, instrument: profileInstrument)
    let earmarked = InstrumentAmount(quantity: earmarkedTotal, instrument: profileInstrument)

    let calendar = Calendar(identifier: .gregorian)
    let dayKey = calendar.startOfDay(for: date)

    return DailyBalance(
      date: dayKey,
      balance: balance,
      earmarked: earmarked,
      availableFunds: balance - earmarked,
      investments: investments,
      investmentValue: nil,
      netWorth: balance + investments,
      bestFit: nil,
      isForecast: isForecast
    )
  }

  /// Sum a per-instrument position dict into a single `Decimal` in `target`,
  /// using the conversion service for non-target instruments. Single-instrument
  /// positions skip the conversion call.
  ///
  /// `.knownZero` source instruments (`.unpriced` / `.spam` crypto
  /// registrations) contribute zero rather than failing the day's
  /// aggregation — issue #790. Real provider errors keep their
  /// per-instrument/date diagnostic log here (callers swallow the
  /// thrown error in the analysis pipeline) before re-throwing.
  private func convert(
    _ positions: [Instrument: Decimal],
    to target: Instrument,
    on date: Date,
    using service: any InstrumentConversionService
  ) async throws -> Decimal {
    var total: Decimal = 0
    for (instrument, quantity) in positions {
      if instrument == target {
        total += quantity
        continue
      }
      do {
        let amount = InstrumentAmount(quantity: quantity, instrument: instrument)
        let result = try await service.convertResult(amount, to: target, on: date)
        switch result {
        case .value(let converted): total += converted.quantity
        case .knownZero: continue
        }
      } catch {
        logger.warning(
          """
          PositionBook conversion failed: \
          \(quantity, privacy: .public) \(instrument.id, privacy: .public) \
          → \(target.id, privacy: .public) on \(date, privacy: .public): \
          \(error.localizedDescription, privacy: .public)
          """
        )
        throw error
      }
    }
    return total
  }
}
