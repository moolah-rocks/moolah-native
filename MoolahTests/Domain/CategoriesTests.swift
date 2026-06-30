import Foundation
import Testing

@testable import Moolah

struct CategoriesTests {
  @Test
  func categoryPathForRootCategory() {
    let root = Category(name: "Groceries")
    let categories = Categories(from: [root])

    #expect(categories.path(for: root) == "Groceries")
  }

  @Test
  func categoryPathForChildCategory() {
    let root = Category(name: "Groceries")
    let child = Category(name: "Food", parentId: root.id)
    let categories = Categories(from: [root, child])

    #expect(categories.path(for: child) == "Groceries:Food")
  }

  @Test
  func categoryPathForDeeplyNestedCategory() {
    let root = Category(name: "Income")
    let mid = Category(name: "Salary", parentId: root.id)
    let leaf = Category(name: "Janet", parentId: mid.id)
    let categories = Categories(from: [root, mid, leaf])

    #expect(categories.path(for: leaf) == "Income:Salary:Janet")
  }

  // MARK: - normalisedSelection(text:id:)

  @Test
  func normalisedSelectionEmptyTextClearsResolvableId() {
    let groceries = Category(name: "Groceries")
    let categories = Categories(from: [groceries])

    let result = categories.normalisedSelection(text: "", id: groceries.id)

    #expect(result.text.isEmpty)
    #expect(result.id == nil)
  }

  @Test
  func normalisedSelectionWhitespaceTextClearsResolvableId() {
    let groceries = Category(name: "Groceries")
    let categories = Categories(from: [groceries])

    let result = categories.normalisedSelection(text: "  \n ", id: groceries.id)

    #expect(result.text.isEmpty)
    #expect(result.id == nil)
  }

  @Test
  func normalisedSelectionResolvableIdRewritesToCanonicalPath() {
    let income = Category(name: "Income")
    let salary = Category(name: "Salary", parentId: income.id)
    let categories = Categories(from: [income, salary])

    let result = categories.normalisedSelection(text: "sal", id: salary.id)

    #expect(result.text == "Income:Salary")
    #expect(result.id == salary.id)
  }

  @Test
  func normalisedSelectionUnresolvableIdClearsBoth() {
    let categories = Categories(from: [])

    let result = categories.normalisedSelection(text: "Made up", id: UUID())

    #expect(result.text.isEmpty)
    #expect(result.id == nil)
  }

  @Test
  func normalisedSelectionNilIdWithTextClearsBoth() {
    let groceries = Category(name: "Groceries")
    let categories = Categories(from: [groceries])

    let result = categories.normalisedSelection(text: "partial input", id: nil)

    #expect(result.text.isEmpty)
    #expect(result.id == nil)
  }

  @Test
  func flattenedSortedAlphabeticallyByPath() {
    let groceries = Category(name: "Groceries")
    let food = Category(name: "Food", parentId: groceries.id)
    let drinks = Category(name: "Drinks", parentId: groceries.id)
    let income = Category(name: "Income")
    let categories = Categories(from: [groceries, food, drinks, income])

    let flattened = categories.flattenedByPath()
    let paths = flattened.map(\.path)

    #expect(paths == ["Groceries", "Groceries:Drinks", "Groceries:Food", "Income"])
  }

  @Test
  func flattenedReturnsEmptyForEmptyCategories() {
    let categories = Categories(from: [])
    #expect(categories.flattenedByPath().isEmpty)
  }

  @Test
  func descendantsOfLeafCategoryIsEmpty() {
    let leaf = Category(name: "Groceries")
    let categories = Categories(from: [leaf])

    #expect(categories.descendants(of: leaf.id).isEmpty)
  }

  @Test
  func descendantsOfParentReturnsDirectChildren() {
    let groceries = Category(name: "Groceries")
    let costco = Category(name: "Costco", parentId: groceries.id)
    let farmers = Category(name: "Farmers Market", parentId: groceries.id)
    let categories = Categories(from: [groceries, costco, farmers])

    let names = Set(categories.descendants(of: groceries.id).map(\.name))

    #expect(names == ["Costco", "Farmers Market"])
  }

  @Test
  func descendantsOfDeepParentReturnsAllLevels() {
    let income = Category(name: "Income")
    let salary = Category(name: "Salary", parentId: income.id)
    let janet = Category(name: "Janet", parentId: salary.id)
    let adrian = Category(name: "Adrian", parentId: salary.id)
    let categories = Categories(from: [income, salary, janet, adrian])

    let names = categories.descendants(of: income.id).map(\.name)

    // Depth-first pre-order; salary's children are sorted alphabetically
    // (Adrian before Janet) by `children(of:)`.
    #expect(names == ["Salary", "Adrian", "Janet"])
  }

  @Test
  func descendantsExcludeSelf() {
    let parent = Category(name: "Groceries")
    let child = Category(name: "Costco", parentId: parent.id)
    let categories = Categories(from: [parent, child])

    let ids = Set(categories.descendants(of: parent.id).map(\.id))

    #expect(!ids.contains(parent.id))
  }

  @Test
  func descendantsExcludeUnrelatedSubtrees() {
    let groceries = Category(name: "Groceries")
    let costco = Category(name: "Costco", parentId: groceries.id)
    let transport = Category(name: "Transport")
    let fuel = Category(name: "Fuel", parentId: transport.id)
    let categories = Categories(from: [groceries, costco, transport, fuel])

    let ids = Set(categories.descendants(of: groceries.id).map(\.id))

    #expect(ids == [costco.id])
    #expect(!ids.contains(transport.id))
    #expect(!ids.contains(fuel.id))
  }

  @Test
  func selectionSummaryEmptyReturnsAll() {
    let categories = Categories(from: [Category(name: "Groceries")])

    #expect(categories.selectionSummary(for: []) == "All")
  }

  @Test
  func selectionSummarySingleSelectionReturnsFullPath() {
    let income = Category(name: "Income")
    let salary = Category(name: "Salary", parentId: income.id)
    let categories = Categories(from: [income, salary])

    #expect(categories.selectionSummary(for: [salary.id]) == "Income:Salary")
  }

  @Test
  func selectionSummaryTwoSelectionsReturnsCount() {
    let groceries = Category(name: "Groceries")
    let transport = Category(name: "Transport")
    let categories = Categories(from: [groceries, transport])

    #expect(categories.selectionSummary(for: [groceries.id, transport.id]) == "2 selected")
  }

  @Test
  func selectionSummaryWithOnePresentAndOrphanIdReturnsSinglePath() {
    let groceries = Category(name: "Groceries")
    let categories = Categories(from: [groceries])
    let orphan = UUID()

    #expect(categories.selectionSummary(for: [groceries.id, orphan]) == "Groceries")
  }

  @Test
  func selectionSummaryWithAllOrphanedIdsReturnsAll() {
    // Empty categories makes the intent unambiguous: no known ids,
    // so every selected id is orphaned and the result is "All".
    let categories = Categories(from: [])

    #expect(categories.selectionSummary(for: [UUID(), UUID()]) == "All")
  }

  @Test
  func flattenedByPathMatchingEmptyQueryReturnsAll() {
    let groceries = Category(name: "Groceries")
    let costco = Category(name: "Costco", parentId: groceries.id)
    let categories = Categories(from: [groceries, costco])

    let entries = categories.flattenedByPath(matching: "")

    #expect(entries.map(\.path) == ["Groceries", "Groceries:Costco"])
  }

  @Test
  func flattenedByPathMatchingFiltersBySubstringCaseInsensitive() {
    let groceries = Category(name: "Groceries")
    let costco = Category(name: "Costco", parentId: groceries.id)
    let income = Category(name: "Income")
    let categories = Categories(from: [groceries, costco, income])

    let entries = categories.flattenedByPath(matching: "cost")

    #expect(entries.map(\.path) == ["Groceries:Costco"])
  }

  @Test
  func flattenedByPathMatchingTrimsLeadingAndTrailingWhitespace() {
    let groceries = Category(name: "Groceries")
    let categories = Categories(from: [groceries])

    let entries = categories.flattenedByPath(matching: "  Groceries  ")

    #expect(entries.map(\.path) == ["Groceries"])
  }

  @Test
  func flattenedByPathMatchingWhitespaceOnlyQueryReturnsAll() {
    // Docstring contract: a whitespace-only query is treated as empty
    // after trimming and returns the full result.
    let groceries = Category(name: "Groceries")
    let income = Category(name: "Income")
    let categories = Categories(from: [groceries, income])

    let entries = categories.flattenedByPath(matching: "   ")

    #expect(entries.map(\.path) == ["Groceries", "Income"])
  }

  @Test
  func flatEntryDepthForRootIsZero() throws {
    let root = Category(name: "Groceries")
    let categories = Categories(from: [root])

    let entry = try #require(categories.flattenedByPath().first)

    #expect(entry.depth == 0)
  }

  @Test
  func flatEntryDepthCountsColonSegments() {
    let income = Category(name: "Income")
    let salary = Category(name: "Salary", parentId: income.id)
    let janet = Category(name: "Janet", parentId: salary.id)
    let categories = Categories(from: [income, salary, janet])

    let depths = categories.flattenedByPath().reduce(into: [String: Int]()) { acc, entry in
      acc[entry.path] = entry.depth
    }

    #expect(depths == ["Income": 0, "Income:Salary": 1, "Income:Salary:Janet": 2])
  }

  @Test
  func subtreeIdsOfLeafReturnsOnlyTheLeaf() {
    let leaf = Category(name: "Groceries")
    let categories = Categories(from: [leaf])

    #expect(categories.subtreeIds(of: leaf.id) == [leaf.id])
  }

  @Test
  func subtreeIdsOfParentIncludesParentAndAllDescendants() {
    let income = Category(name: "Income")
    let salary = Category(name: "Salary", parentId: income.id)
    let janet = Category(name: "Janet", parentId: salary.id)
    let categories = Categories(from: [income, salary, janet])

    #expect(categories.subtreeIds(of: income.id) == [income.id, salary.id, janet.id])
  }

  @Test
  func subtreeIdsOfMissingIdReturnsOnlyTheMissingId() {
    // Out-of-tree behaviour: returns the id alone (no descendants found).
    // Callers using it for selection still get a correct, no-op-ish result.
    let categories = Categories(from: [])
    let phantom = UUID()

    #expect(categories.subtreeIds(of: phantom) == [phantom])
  }

  @Test
  func hasChildrenReturnsFalseForLeaf() {
    let leaf = Category(name: "Groceries")
    let categories = Categories(from: [leaf])

    #expect(categories.hasChildren(leaf.id) == false)
  }

  @Test
  func hasChildrenReturnsTrueForParent() {
    let income = Category(name: "Income")
    let salary = Category(name: "Salary", parentId: income.id)
    let categories = Categories(from: [income, salary])

    #expect(categories.hasChildren(income.id) == true)
  }

  @Test
  func hasChildrenReturnsFalseForMissingId() {
    let categories = Categories(from: [])

    #expect(categories.hasChildren(UUID()) == false)
  }
}
