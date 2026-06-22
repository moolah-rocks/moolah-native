import Foundation

/// Daily-balance read path for `PositionBook`. Converts the book's
/// per-instrument positions to a profile instrument and assembles a
/// `DailyBalance` snapshot.
///
/// A request/resolve/assemble split lets a caller walking many days batch
/// every day's conversions into a single `convertResultBatch(_:)`:
/// `dailyBalanceRequests(on:context:)` emits the tagged requests,
/// `convertResultBatch(_:)` resolves them in one `await`, and
/// `assembleDailyBalance(on:context:accumulation:outcomes:isForecast:)`
/// folds the outcomes back into a `DailyBalance`.
/// `dailyBalance(on:context:isForecast:)` is a single-day shim over the
/// three phases for the forecast accumulator and the contract tests.
extension PositionBook {

  /// Calendar for keying `DailyBalance.date` to a day boundary. Hoisted to
  /// a static so `assembleDailyBalance(...)` doesn't allocate one per call.
  private static let dayKeyCalendar = Calendar(identifier: .gregorian)

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

  /// Which daily-balance bucket a conversion request feeds. Tags every
  /// `BatchConversionRequest` emitted by `dailyBalanceRequests(on:context:)`
  /// so `assembleDailyBalance(...)` can route each resolved outcome back to
  /// its `bankTotal` / `investmentsTotal` / per-earmark sum.
  enum DailyBalanceBucket: Sendable, Equatable {
    case bank
    case investments
    /// Carries the earmark id so the per-earmark `max(_, 0)` clamp is
    /// applied per owner, not across the whole earmarked total.
    case earmark(UUID)
  }

  /// A single conversion request tagged with the bucket it feeds. The
  /// `request` is index-aligned with the outcome `convertResultBatch(_:)`
  /// returns; `bucket` routes that outcome during assembly.
  struct DailyBalanceConversionTag: Sendable {
    let request: BatchConversionRequest
    let bucket: DailyBalanceBucket
  }

  /// The synchronous output of `dailyBalanceRequests(on:context:)`: the
  /// tagged conversion requests for non-target positions, plus the
  /// same-instrument fast-path subtotals that never reach the conversion
  /// service. `assembleDailyBalance(...)` sums the fast-path subtotals with
  /// the resolved request outcomes to rebuild the `DailyBalance`.
  struct DailyBalanceAccumulation: Sendable {
    /// One tagged request per non-target `(bucket, instrument)` position.
    var tags: [DailyBalanceConversionTag] = []
    /// Bank positions already in `profileInstrument` — no conversion.
    var bankFastPath: Decimal = 0
    /// Investment positions already in `profileInstrument` — no conversion.
    var investmentsFastPath: Decimal = 0
    /// Per-earmark same-instrument subtotals — clamped with the converted
    /// per-earmark sum in `assembleDailyBalance(...)`.
    var earmarkFastPath: [UUID: Decimal] = [:]
  }

  /// Emit the tagged conversion requests (plus same-instrument fast-path
  /// subtotals) needed to build a `DailyBalance` from the current book
  /// state, without performing any conversion. The bucket selection and
  /// `rule` switch mirror `dailyBalance(on:context:isForecast:)` exactly;
  /// only the conversion is deferred to a batched `convertResultBatch(_:)`.
  ///
  /// Positions whose instrument equals `profileInstrument` are summed into
  /// the matching fast-path field (never a request); every other position
  /// becomes one `BatchConversionRequest` tagged with its bucket.
  ///
  /// Synchronous by construction — the caller batches the requests across
  /// days into a single `await`.
  func dailyBalanceRequests(
    on date: Date,
    context: BalanceContext
  ) -> DailyBalanceAccumulation {
    let investmentAccountIds = context.investmentAccountIds
    var accumulation = DailyBalanceAccumulation()

    // Bank balance: all non-investment account positions.
    for (accountId, positions) in accounts where !investmentAccountIds.contains(accountId) {
      collect(positions, on: date, bucket: .bank, context: context, into: &accumulation)
    }

    // Investments: depending on rule.
    switch context.rule {
    case .allLegs:
      for (accountId, positions) in accounts where investmentAccountIds.contains(accountId) {
        collect(
          positions, on: date, bucket: .investments, context: context, into: &accumulation)
      }
    case .investmentTransfersOnly:
      for (accountId, positions) in accountsFromTransfers
      where investmentAccountIds.contains(accountId) {
        collect(
          positions, on: date, bucket: .investments, context: context, into: &accumulation)
      }
    }

    // Earmarks: per-earmark, tracked separately so the `max(_, 0)` clamp
    // applies per owner in `assembleDailyBalance(...)`.
    for (earmarkId, positions) in earmarks {
      collect(
        positions, on: date, bucket: .earmark(earmarkId), context: context, into: &accumulation)
    }

    return accumulation
  }

  /// Split one position dict into same-instrument fast-path subtotal and
  /// tagged conversion requests for the rest, routing each into `bucket`'s
  /// slot of `accumulation`. Shared by every bucket so the
  /// request/fast-path partition stays identical to the old
  /// same-instrument fast path.
  private func collect(
    _ positions: [Instrument: Decimal],
    on date: Date,
    bucket: DailyBalanceBucket,
    context: BalanceContext,
    into accumulation: inout DailyBalanceAccumulation
  ) {
    let profileInstrument = context.profileInstrument
    for (instrument, quantity) in positions {
      if instrument == profileInstrument {
        switch bucket {
        case .bank: accumulation.bankFastPath += quantity
        case .investments: accumulation.investmentsFastPath += quantity
        case .earmark(let earmarkId):
          accumulation.earmarkFastPath[earmarkId, default: 0] += quantity
        }
        continue
      }
      let amount = InstrumentAmount(quantity: quantity, instrument: instrument)
      accumulation.tags.append(
        DailyBalanceConversionTag(
          request: BatchConversionRequest(
            amount: amount, target: profileInstrument, date: date),
          bucket: bucket))
    }
  }

  /// Rebuild a `DailyBalance` from a previously-emitted accumulation and the
  /// `outcomes` that `convertResultBatch(_:)` returned for its tagged
  /// requests (in the same order the tags were emitted).
  ///
  /// Semantics match `dailyBalance(on:context:isForecast:)`:
  /// - `balance` sums bank fast-path + bank-bucket `.value`s.
  /// - `investments` sums the investments fast-path + investments-bucket
  ///   `.value`s under the rule the requests were emitted with.
  /// - `earmarked` sums each earmark's fast-path + `.value`s, clamps each
  ///   per-earmark sum to `>= 0`, then totals.
  /// - `.knownZero` outcomes contribute exactly zero (issue #790).
  /// - Any `.failure` outcome throws the carried error so the caller's
  ///   Rule 11 per-day drop fires.
  /// - `availableFunds = balance - earmarked`; `netWorth = balance +
  ///   investments`; `investmentValue` / `bestFit` left `nil`.
  func assembleDailyBalance(
    on date: Date,
    context: BalanceContext,
    accumulation: DailyBalanceAccumulation,
    outcomes: [BatchConversionOutcome],
    isForecast: Bool
  ) throws -> DailyBalance {
    let profileInstrument = context.profileInstrument
    var bankTotal = accumulation.bankFastPath
    var investmentsTotal = accumulation.investmentsFastPath
    var earmarkTotals = accumulation.earmarkFastPath

    for (tag, outcome) in zip(accumulation.tags, outcomes) {
      let converted = try Self.value(of: outcome)
      switch tag.bucket {
      case .bank: bankTotal += converted
      case .investments: investmentsTotal += converted
      case .earmark(let earmarkId): earmarkTotals[earmarkId, default: 0] += converted
      }
    }

    // Per-earmark clamp to >= 0, then total. Negative earmarks (e.g. those
    // funding investments) do not reduce the total.
    let earmarkedTotal = earmarkTotals.values.reduce(into: Decimal(0)) { total, perEarmark in
      total += max(perEarmark, 0)
    }

    let balance = InstrumentAmount(quantity: bankTotal, instrument: profileInstrument)
    let investments = InstrumentAmount(quantity: investmentsTotal, instrument: profileInstrument)
    let earmarked = InstrumentAmount(quantity: earmarkedTotal, instrument: profileInstrument)

    let dayKey = Self.dayKeyCalendar.startOfDay(for: date)

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

  /// Reduce a single `BatchConversionOutcome` to the `Decimal` it
  /// contributes: `.value` adds its quantity, `.knownZero` adds zero
  /// (issue #790), `.failure` throws so the caller drops the day (Rule 11).
  private static func value(of outcome: BatchConversionOutcome) throws -> Decimal {
    switch outcome {
    case .value(let converted): return converted.quantity
    case .knownZero: return 0
    case .failure(let error): throw error
    }
  }

  /// Build a `DailyBalance` snapshot from the current book state, converting
  /// per-instrument positions to `profileInstrument` on `date`.
  ///
  /// Thin shim over the `dailyBalanceRequests` / `convertResultBatch` /
  /// `assembleDailyBalance` split: emits this day's requests, resolves them
  /// in one batch, and assembles. Callers that walk many days should drive
  /// the three phases directly and batch across days; this single-day
  /// convenience preserves the original async signature for the forecast
  /// accumulator and the existing contract tests.
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
    let accumulation = dailyBalanceRequests(on: date, context: context)
    let outcomes = try await context.conversionService.convertResultBatch(
      accumulation.tags.map(\.request))
    return try assembleDailyBalance(
      on: date,
      context: context,
      accumulation: accumulation,
      outcomes: outcomes,
      isForecast: isForecast)
  }
}
