import Foundation

extension ReadFinancialCalculationService {
  func summary(
    _ snapshot: ReadSummarySnapshot,
    target: Instrument,
    grouping: ReadSummaryGrouping,
    includeParentTotals: Bool = true
  ) async throws -> (ReadSummaryDTO, [String]) {
    let flows = snapshot.flows.filter { $0.type == .income || $0.type == .expense }
    guard !grouping.includesCategories || Set(flows.map(\.categoryID)).count <= 500 else {
      throw ReadLimitError(operation: .summaryGroups, unit: .calculationGroups, maximum: 500)
    }
    let buckets = try summaryBuckets(flows, grouping: grouping, timeZone: snapshot.timeZone)
    let valuations = try await value(
      buckets.map { ReadDatedAmount(amount: $0.amount, date: $0.date) },
      target: target
    )
    let income = flows.filter { $0.type == .income }.map(\.amount)
    let spending = flows.filter { $0.type == .expense }.map(\.amount)
    let (current, netWorthWarnings) = try await netWorth(
      snapshot.netWorth,
      target: target,
      on: snapshot.queriedAt
    )
    let groups = try summaryGroups(
      ReadSummaryGroupContext(
        buckets: buckets,
        values: valuations,
        categories: snapshot.categories,
        target: target,
        grouping: grouping,
        includeParentTotals: includeParentTotals
      )
    )
    let result = ReadSummaryDTO(
      semantics:
        "Income and spending follow Moolah Reports. They exclude transfers, trades, opening balances, scheduled transactions and uncategorised reserve movements without an account. Signs are preserved, so spending is usually negative. current_net_worth is omitted unless include_net_worth is true. When included, it uses posted balances from every account, including hidden accounts and future-dated transactions. Flow conversions use each transaction’s UTC calendar day. When included, net worth uses prices at queried_at. Prices are read separately from the financial data snapshot. Month values use YYYY-MM for Gregorian months in the requested time zone. Only months with report flows are returned. Category rows with includes_descendants true overlap: use the overall totals instead of adding those rows together.",
      reportingInstrument: ReadInstrumentDTO(target),
      groupBy: grouping.rawValue,
      income: wireTotals(income),
      spending: wireTotals(spending),
      reportingIncome: total(
        selected(.income, buckets: buckets, values: valuations),
        target: target,
        on: nil
      ).dto,
      reportingSpending: total(
        selected(.expense, buckets: buckets, values: valuations),
        target: target,
        on: nil
      ).dto,
      currentNetWorth: current,
      netWorthIncluded: current != nil,
      groups: groups
    )
    return (result, Array(Set(warnings(valuations) + netWorthWarnings)).sorted())
  }

  private func netWorth(_ input: ReadNetWorthInput, target: Instrument, on date: Date) async throws
    -> (ReadValuationDTO?, [String])
  {
    guard case .requested(let balances) = input else { return (nil, []) }
    let positions = nativeTotals(balances.flatMap(\.positions))
    let values = try await value(
      positions.map { ReadDatedAmount(amount: $0, date: date) },
      target: target
    )
    return (total(values, target: target, on: date).dto, warnings(values))
  }

  private func selected(
    _ type: TransactionType,
    buckets: [ReadSummaryBucket],
    values: [ReadValuation]
  ) -> [ReadValuation] {
    zip(buckets, values).filter { $0.0.type == type }.map(\.1)
  }

  private func summaryBuckets(
    _ flows: [ReadSummaryFlow],
    grouping: ReadSummaryGrouping,
    timeZone: TimeZone
  )
    throws -> [ReadSummaryBucket]
  {
    var buckets: [ReadSummaryBucketKey: InstrumentAmount] = [:]
    var calendar = Calendar.utc
    calendar.timeZone = timeZone
    for flow in flows {
      let key = ReadSummaryBucketKey(
        day: Calendar.utc.startOfDay(for: flow.date),
        month: grouping.includesMonths ? try Self.summaryMonth(flow.date, calendar: calendar) : nil,
        type: flow.type,
        categoryID: grouping.includesCategories ? flow.categoryID : nil,
        instrumentID: flow.amount.instrument.id
      )
      let previous = buckets[key]?.quantity ?? 0
      buckets[key] = InstrumentAmount(
        quantity: previous + flow.amount.quantity,
        instrument: flow.amount.instrument
      )
    }
    return buckets.keys.sorted().compactMap { key in
      buckets[key].map {
        ReadSummaryBucket(
          date: key.day,
          month: key.month,
          categoryID: key.categoryID,
          type: key.type,
          amount: $0
        )
      }
    }
  }

  func nativeTotals(_ amounts: [InstrumentAmount]) -> [InstrumentAmount] {
    var totals: [String: InstrumentAmount] = [:]
    for amount in amounts {
      let previous = totals[amount.instrument.id]?.quantity ?? 0
      totals[amount.instrument.id] = InstrumentAmount(
        quantity: previous + amount.quantity,
        instrument: amount.instrument
      )
    }
    return totals.keys.sorted().compactMap { totals[$0] }
  }

  func wireTotals(_ amounts: [InstrumentAmount]) -> [ReadQuantityDTO] {
    nativeTotals(amounts).map { ReadQuantityDTO(quantity: $0.quantity, instrument: $0.instrument) }
  }
}

private struct ReadSummaryBucketKey {
  let day: Date
  let month: String?
  let type: TransactionType
  let categoryID: UUID?
  let instrumentID: String

}

extension ReadSummaryBucketKey: Hashable {}
extension ReadSummaryBucketKey: Sendable {}
extension ReadSummaryBucketKey: Comparable {
  static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.day != rhs.day { return lhs.day < rhs.day }
    if lhs.month != rhs.month { return (lhs.month ?? "") < (rhs.month ?? "") }
    if lhs.type != rhs.type { return lhs.type.rawValue < rhs.type.rawValue }
    if lhs.categoryID != rhs.categoryID {
      return (lhs.categoryID?.uuidString ?? "") < (rhs.categoryID?.uuidString ?? "")
    }
    return lhs.instrumentID < rhs.instrumentID
  }
}

extension ReadFinancialCalculationService {
  private static func summaryMonth(_ date: Date, calendar: Calendar) throws -> String {
    let components = calendar.dateComponents([.year, .month], from: date)
    guard let year = components.year, (1...9999).contains(year), let month = components.month else {
      throw ReadCalculationError.invalidResult
    }
    return String(format: "%04d-%02d", year, month)
  }
}
