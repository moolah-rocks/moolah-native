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
    #expect(InsightNavigationTarget.sidebarSelection(for: refs) == .account(accountId))
  }

  @Test
  func earmarkReferenceMapsToEarmarkSelection() {
    let refs = InsightReferences(earmarkIds: [earmarkId])
    #expect(InsightNavigationTarget.sidebarSelection(for: refs) == .earmark(earmarkId))
  }

  @Test
  func groupReferenceMapsToGroupSelection() {
    let refs = InsightReferences(groupIds: [groupId])
    #expect(InsightNavigationTarget.sidebarSelection(for: refs) == .group(groupId))
  }

  @Test
  func categoryReferenceMapsToCategoriesScreen() {
    let refs = InsightReferences(categoryIds: [categoryId])
    #expect(InsightNavigationTarget.sidebarSelection(for: refs) == .categories)
  }

  @Test
  func priorityIsAccountThenEarmarkThenGroupThenCategories() {
    let refs = InsightReferences(
      accountIds: [accountId], categoryIds: [categoryId],
      earmarkIds: [earmarkId], groupIds: [groupId])
    #expect(InsightNavigationTarget.sidebarSelection(for: refs) == .account(accountId))
  }

  @Test
  func instrumentOrTransactionOnlyHasNoTarget() {
    let refs = InsightReferences(instrumentIds: ["ETH"], transactionIds: [UUID()])
    #expect(InsightNavigationTarget.sidebarSelection(for: refs) == nil)
  }

  @Test
  func emptyReferencesHaveNoTarget() {
    #expect(InsightNavigationTarget.sidebarSelection(for: InsightReferences()) == nil)
  }
}
