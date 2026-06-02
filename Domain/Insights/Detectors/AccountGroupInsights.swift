import Foundation

/// Account-group insights (research follow-up §A-1) — the first detector to
/// exploit the post-design-doc account-groups feature. Surfaces when one
/// group accounts for a dominant share of recent spending, so the user sees
/// where the money actually flows out.
enum AccountGroupInsights {
  static func groupSpendConcentration(
    _ input: InsightInput,
    windowDays: Int = 30,
    minimumShare: Double = 0.6
  ) -> [Insight] {
    let context = input.context
    let groupsById = Dictionary(uniqueKeysWithValues: input.accountGroups.map { ($0.id, $0) })
    guard groupsById.count >= 2 else { return [] }

    var spendByGroup: [UUID: Double] = [:]
    var groupedTotal = 0.0
    for summary in input.accountSpend {
      guard let accountId = summary.accountId,
        let groupId = input.accountGroupMembership[accountId]
      else { continue }
      let magnitudeDecimal = summary.total.quantity < 0 ? -summary.total.quantity : 0
      let magnitude = Double(truncating: magnitudeDecimal as NSDecimalNumber)
      spendByGroup[groupId, default: 0] += magnitude
      groupedTotal += magnitude
    }
    guard groupedTotal > 0,
      let top = spendByGroup.max(by: { $0.value < $1.value }),
      let group = groupsById[top.key]
    else { return [] }

    let share = top.value / groupedTotal
    guard share >= minimumShare else { return [] }

    return [
      Insight(
        id: "\(InsightKind.groupSpendConcentration.rawValue):\(group.id.uuidString)",
        kind: .groupSpendConcentration,
        title: "Most spending runs through \(group.name)",
        detail:
          "\(percent(share)) of your spending in the last \(windowDays) days "
          + "(\(context.formatted(Decimal(-top.value)))) came from accounts in your "
          + "\(group.name) group.",
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
