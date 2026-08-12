import Foundation
import Testing

@testable import Moolah

@Suite("InsightNavigationTarget")
struct InsightNavigationTargetTests {
  private let accountId = UUID()
  private let earmarkId = UUID()
  private let groupId = UUID()
  private let categoryId = UUID()

  @Test
  func accountReferenceMapsToAccountSelection() {
    let refs = InsightReferences(accountIds: [accountId])
    #expect(
      InsightNavigationTarget.target(for: makeInsight(references: refs))
        == .sidebar(.account(accountId)))
  }

  @Test
  func earmarkReferenceMapsToEarmarkSelection() {
    let refs = InsightReferences(earmarkIds: [earmarkId])
    #expect(
      InsightNavigationTarget.target(for: makeInsight(references: refs))
        == .sidebar(.earmark(earmarkId)))
  }

  @Test
  func groupReferenceMapsToGroupSelection() {
    let refs = InsightReferences(groupIds: [groupId])
    #expect(
      InsightNavigationTarget.target(for: makeInsight(references: refs))
        == .sidebar(.group(groupId)))
  }

  @Test
  func categoryReferenceMapsToFilteredTransactions() {
    let refs = InsightReferences(categoryIds: [categoryId])
    let insight = makeInsight(references: refs)
    #expect(
      InsightNavigationTarget.target(for: insight)
        == .transactions(
          TransactionFilter(
            scheduled: .nonScheduledOnly,
            categoryIds: [categoryId])))
  }

  @Test
  func groupPriorityBeatsAccountAndCategoryTransactions() {
    let refs = InsightReferences(
      accountIds: [accountId], categoryIds: [categoryId],
      groupIds: [groupId])
    #expect(
      InsightNavigationTarget.target(for: makeInsight(references: refs))
        == .sidebar(.group(groupId)))
  }

  @Test
  func earmarkPriorityBeatsGroupAndCategoryTransactions() {
    let refs = InsightReferences(
      categoryIds: [categoryId], earmarkIds: [earmarkId], groupIds: [groupId])
    #expect(
      InsightNavigationTarget.target(for: makeInsight(references: refs))
        == .sidebar(.earmark(earmarkId)))
  }

  @Test
  func categoryTransactionsBeatAccountDestination() {
    let refs = InsightReferences(accountIds: [accountId], categoryIds: [categoryId])
    #expect(
      InsightNavigationTarget.target(for: makeInsight(references: refs))
        == .transactions(
          TransactionFilter(
            scheduled: .nonScheduledOnly,
            categoryIds: [categoryId])))
  }

  @Test
  func explicitTransactionFilterBeatsEntityReferences() {
    let filter = TransactionFilter(
      scheduled: .nonScheduledOnly,
      dateRange: Date(timeIntervalSince1970: 100)...Date(timeIntervalSince1970: 200),
      categoryIds: [categoryId],
      transactionTypes: [.expense])
    let refs = InsightReferences(
      accountIds: [accountId],
      categoryIds: [categoryId],
      transactionFilter: filter)

    #expect(
      InsightNavigationTarget.target(for: makeInsight(references: refs))
        == .transactions(filter))
  }

  @Test
  func instrumentOrTransactionOnlyHasNoTarget() {
    let refs = InsightReferences(instrumentIds: ["ETH"], transactionIds: [UUID()])
    #expect(InsightNavigationTarget.target(for: makeInsight(references: refs)) == nil)
  }

  @Test
  func emptyReferencesHaveNoTarget() {
    #expect(
      InsightNavigationTarget.target(for: makeInsight(references: InsightReferences())) == nil)
  }

  private func makeInsight(references: InsightReferences) -> Insight {
    Insight(
      id: "navigation-test",
      kind: .feeSpend,
      title: "Navigation test",
      date: Date(timeIntervalSince1970: 1_000),
      framing: .neutral,
      actionability: .review,
      surprise: 0,
      references: references)
  }
}
