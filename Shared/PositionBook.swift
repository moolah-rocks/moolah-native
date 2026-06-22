import Foundation

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

}
