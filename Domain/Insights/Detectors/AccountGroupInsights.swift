import Foundation

/// Account-group insights (research follow-up §A-1) — the first detector to
/// exploit the post-design-doc account-groups feature. Surfaces when one
/// group accounts for a dominant share of recent spending, so the user sees
/// where the money actually flows out.
enum AccountGroupInsights {
  static func groupSpendConcentration(
    _ input: InsightInput,
    minimumShare: Double = 0.6,
    minimumLegs: Int = 5
  ) -> [Insight] {
    let context = input.context
    let groupsById = Dictionary(uniqueKeysWithValues: input.accountGroups.map { ($0.id, $0) })
    guard groupsById.count >= 2 else { return [] }

    // The share the message quotes is "% of your spending", so the
    // denominator must be *all* spend — including accounts that belong to no
    // group. Dividing only by grouped spend inflated the share (a group could
    // read as "most of your spending" while ungrouped accounts held the bulk
    // of it).
    var spendByGroup: [UUID: Double] = [:]
    var totalSpend = 0.0
    var totalLegCount = 0
    for summary in input.accountSpend {
      let magnitudeDecimal = summary.total.quantity < 0 ? -summary.total.quantity : 0
      let magnitude = Double(truncating: magnitudeDecimal as NSDecimalNumber)
      totalSpend += magnitude
      totalLegCount += summary.legCount
      guard let accountId = summary.accountId,
        let groupId = input.accountGroupMembership[accountId]
      else { continue }
      spendByGroup[groupId, default: 0] += magnitude
    }
    // Too little activity to call any group "dominant" — a lone expense would
    // otherwise fire this at a 100% share. `totalLegCount` is the count of
    // expense legs across all accounts (`accountSpend` is expense-only).
    guard totalSpend > 0, totalLegCount >= minimumLegs,
      let top = spendByGroup.max(by: { $0.value < $1.value }),
      let group = groupsById[top.key]
    else { return [] }

    let share = top.value / totalSpend
    guard share >= minimumShare else { return [] }

    return [
      Insight(
        id: "\(InsightKind.groupSpendConcentration.rawValue):\(group.id.uuidString)",
        kind: .groupSpendConcentration,
        title: "Most spending runs through \(group.name)",
        date: context.now,
        framing: .neutral,
        actionability: .informational,
        surprise: min(share, 1),
        monetaryImpact: InstrumentAmount(
          quantity: Decimal(-top.value), instrument: context.reportingCurrency),
        facts: [
          InsightFact("Group", group.name),
          InsightFact("Share of spend", percent(share)),
          InsightFact("Spent", context.formatted(Decimal(-top.value))),
        ],
        references: InsightReferences(
          groupIds: [group.id], instrumentIds: [context.reportingCurrency.id]))
    ]
  }

  private static func percent(_ fraction: Double) -> String {
    fraction.formatted(.percent.precision(.fractionLength(0)))
  }
}
