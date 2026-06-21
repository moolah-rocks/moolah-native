import Foundation
import GRDB

/// Per-day investment-value fold-in for `fetchDailyBalances`. Walks
/// the per-day balances in date order, tracks the latest recorded
/// value per investment account, and overwrites each day's
/// `DailyBalance` with the converted-to-profile-instrument total —
/// driving the `investmentValue` and `netWorth` fields. Also owns the
/// SQL fetches that produce the inputs to that fold-in
/// (`fetchInvestmentAccountIds`, `fetchInvestmentValueSnapshots`).
extension GRDBAnalysisRepository {

  // MARK: - SQL fetches

  /// Loads every account id of an investment-like `type`
  /// (`investmentLikeTypesSQLList`) whose `valuation_mode =
  /// 'recordedValue'`. The Swift assembly walks per-day deltas and
  /// folds in snapshot values for these accounts; trades-mode
  /// investment accounts are intentionally excluded because their
  /// per-day value comes from a different path and they have no
  /// snapshot fold to apply — including them here would overwrite their
  /// daily balance with a stale or missing snapshot. Classifying by the
  /// investment-like type set (not the literal `type = 'investment'`)
  /// keeps crypto/exchange accounts out of the bank-balance sum.
  /// Reading the column directly off the `account` table avoids
  /// redundantly carrying the full account row across the snapshot
  /// boundary.
  static func fetchInvestmentAccountIds(database: Database) throws -> Set<UUID> {
    let rows = try Row.fetchAll(
      database,
      sql: """
        SELECT id FROM account
        WHERE type IN (\(GRDBAnalysisRepository.investmentLikeTypesSQLList))
          AND valuation_mode = 'recordedValue'
        """)
    var ids = Set<UUID>()
    ids.reserveCapacity(rows.count)
    for row in rows {
      if let id: UUID = row["id"] {
        ids.insert(id)
      }
    }
    return ids
  }

  /// Loads every account id of an investment-like `type`
  /// (`investmentLikeTypesSQLList`) whose `valuation_mode =
  /// 'calculatedFromTrades'` — the manual investment accounts the
  /// migration flipped, plus crypto wallets and exchange accounts,
  /// which are created in trades mode. The trades-mode fold
  /// (`applyTradesModePositionValuations`) walks per-day position
  /// deltas for these accounts and valuates the cumulative positions
  /// against the conversion service on the day's date. Recorded-value
  /// investment accounts are intentionally excluded — they contribute
  /// via the snapshot fold instead. Classifying by the investment-like
  /// type set (not the literal `type = 'investment'`) is what keeps
  /// crypto/exchange market value out of the bank-balance sum and in
  /// the investments total. Reading the column directly off the
  /// `account` table avoids carrying the full account row across the
  /// position-row boundary.
  static func fetchTradesModeInvestmentAccountIds(
    database: Database
  ) throws -> Set<UUID> {
    let rows = try Row.fetchAll(
      database,
      sql: """
        SELECT id FROM account
        WHERE type IN (\(GRDBAnalysisRepository.investmentLikeTypesSQLList))
          AND valuation_mode = 'calculatedFromTrades'
        """)
    var ids = Set<UUID>()
    ids.reserveCapacity(rows.count)
    for row in rows {
      if let id: UUID = row["id"] {
        ids.insert(id)
      }
    }
    return ids
  }

  /// Loads the per-account latest-as-of-day investment values pinned
  /// by
  /// `DailyBalancesPlanPinningTests.fetchDailyBalancesInvestmentValuesUseAccountDateIndex`.
  /// The composite `iv_by_account_date_value` covers
  /// `(account_id, date, value, instrument_id)` so the SELECT list is
  /// served by the index — SQLite emits `SCAN ... USING COVERING
  /// INDEX`, which is the no-base-row read shape we want and is *not*
  /// a full table scan.
  ///
  /// All historical snapshots are loaded — there is intentionally no
  /// `:after` lower bound. The cursor walk in `applyInvestmentValues`
  /// (`advanceInvestmentCursor`) carries the most-recent pre-window
  /// snapshot forward into the first in-window day; filtering the
  /// loader on `date >= :after` would silently drop that baseline
  /// snapshot and zero out the in-window investment value.
  ///
  /// Filtered to investment accounts in Swift (the same shape as the
  /// previous SwiftData-backed path) so the SQL stays index-friendly
  /// — adding the account-type predicate to the WHERE would force an
  /// `account` join and break the covering index.
  ///
  /// `instrumentMap` is consulted to resolve each row's stored
  /// `instrument_id` to its registered `Instrument` so stock / crypto
  /// investment values surface with the correct `kind`. Falls back to
  /// `Instrument.fiat(code:)` when the registry has no entry for the
  /// id — matching the same `resolveInstrument` pattern used by the
  /// account / earmark delta decoders.
  static func fetchInvestmentValueSnapshots(
    database: Database,
    investmentAccountIds: Set<UUID>,
    instrumentMap: [String: Instrument]
  ) throws -> [InvestmentValueSnapshot] {
    guard !investmentAccountIds.isEmpty else { return [] }
    let sql = """
      SELECT account_id, date, value, instrument_id
      FROM investment_value
      ORDER BY account_id ASC, date ASC
      """
    let sqlRows = try Row.fetchAll(database, sql: sql)
    var snapshots: [InvestmentValueSnapshot] = []
    snapshots.reserveCapacity(sqlRows.count)
    for row in sqlRows {
      guard let accountId: UUID = row["account_id"] else { continue }
      guard investmentAccountIds.contains(accountId) else { continue }
      guard let date: Date = row["date"] else { continue }
      guard let value: Int64 = row["value"] else { continue }
      guard let instrumentId: String = row["instrument_id"] else { continue }
      let instrument = instrumentMap[instrumentId] ?? Instrument.fiat(code: instrumentId)
      let amount = InstrumentAmount(storageValue: value, instrument: instrument)
      snapshots.append(
        InvestmentValueSnapshot(
          accountId: accountId, date: date, value: amount))
    }
    snapshots.sort { $0.date < $1.date }
    return snapshots
  }

  // MARK: - Per-day fold-in
  /// Per-day investment-value override: for each recorded-value
  /// investment account, carries the latest snapshot forward to each
  /// day and replaces the bank-balance-derived `investmentValue`
  /// with the converted total.
  ///
  /// Rule 11 contract (same as `walkDays`): a conversion failure on a
  /// single day drops that day from `dailyBalances` via
  /// `removeValue(forKey:)` so the chart shows a gap rather than an
  /// incorrect partial total. Sibling days are unaffected.
  /// `CancellationError` rethrows immediately and is never routed
  /// through the failure callback.
  ///
  /// `Task.checkCancellation()` at the top of the per-day loop covers
  /// the all-fast-path case (every snapshot already in the profile
  /// instrument): no `await` would otherwise occur, so the runtime
  /// would never get a chance to surface cancellation.
  static func applyInvestmentValues(
    _ investmentValues: [InvestmentValueSnapshot],
    to dailyBalances: inout [Date: DailyBalance],
    context: DailyBalancesAssemblyContext,
    handlers: DailyBalancesHandlers
  ) async throws {
    guard !investmentValues.isEmpty, !dailyBalances.isEmpty else { return }
    var latestByAccount: [UUID: InstrumentAmount] = [:]
    var valueIndex = 0
    for date in dailyBalances.keys.sorted() {
      // The Rule 8 fast path can let the loop run synchronously when
      // every snapshot is in the profile instrument; an explicit
      // cancellation check ensures the outer task can be torn down
      // promptly even in that case.
      try Task.checkCancellation()
      valueIndex = advanceInvestmentCursor(
        values: investmentValues,
        latestByAccount: &latestByAccount,
        from: valueIndex,
        upTo: date)
      if latestByAccount.isEmpty { continue }
      let totalValue: InstrumentAmount
      do {
        totalValue = try await sumInvestmentValues(
          latestByAccount: latestByAccount,
          on: date,
          profileInstrument: context.profileInstrument,
          conversionService: context.conversionService)
      } catch let cancel as CancellationError {
        throw cancel
      } catch {
        // Rule 11: drop the day from dailyBalances so the chart shows
        // a gap rather than rendering a partial total. Matches the
        // walkDays per-day error contract.
        handlers.handleInvestmentValueFailure(error, date)
        dailyBalances.removeValue(forKey: date)
        continue
      }
      guard let balance = dailyBalances[date] else { continue }
      dailyBalances[date] = DailyBalance(
        date: balance.date,
        balance: balance.balance,
        earmarked: balance.earmarked,
        availableFunds: balance.availableFunds,
        investments: balance.investments,
        investmentValue: totalValue,
        netWorth: balance.balance + totalValue,
        bestFit: balance.bestFit,
        isForecast: balance.isForecast)
    }
  }

  /// Advance the sorted investment-values cursor, updating the
  /// per-account latest map with every entry whose day is on-or-before
  /// `date`.
  private static func advanceInvestmentCursor(
    values: [InvestmentValueSnapshot],
    latestByAccount: inout [UUID: InstrumentAmount],
    from startIndex: Int,
    upTo date: Date
  ) -> Int {
    var valueIndex = startIndex
    while valueIndex < values.count {
      let entry = values[valueIndex]
      let entryDay = Calendar.current.startOfDay(for: entry.date)
      if entryDay <= date {
        latestByAccount[entry.accountId] = entry.value
        valueIndex += 1
      } else {
        break
      }
    }
    return valueIndex
  }

  /// Sum the per-account investment values, converting foreign
  /// instruments to the profile instrument on `date`. Throws on any
  /// conversion failure so the caller can drop the day from the
  /// `dailyBalances` dict per Rule 11. The return is non-optional —
  /// the function either throws or returns the converted total.
  private static func sumInvestmentValues(
    latestByAccount: [UUID: InstrumentAmount],
    on date: Date,
    profileInstrument: Instrument,
    conversionService: any InstrumentConversionService
  ) async throws -> InstrumentAmount {
    var total: Decimal = 0
    for value in latestByAccount.values {
      if value.instrument.id == profileInstrument.id {
        total += value.quantity
        continue
      }
      // `.knownZero` (e.g. an `.unpriced` / `.spam` crypto investment
      // value) contributes zero rather than failing the day —
      // issue #790.
      let result = try await conversionService.convertResult(
        value, to: profileInstrument, on: date)
      if case .value(let converted) = result {
        total += converted.quantity
      }
    }
    return InstrumentAmount(quantity: total, instrument: profileInstrument)
  }
}
