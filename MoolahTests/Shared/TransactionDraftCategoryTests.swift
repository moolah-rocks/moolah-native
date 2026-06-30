import Foundation
import Testing

@testable import Moolah

@Suite("TransactionDraft.normaliseCategoryText")
struct TransactionDraftCategoryTests {
  private let support = TransactionDraftTestSupport()

  // swiftlint:disable:next attributes
  @Test func validCategoryIdRewritesTextToCanonicalPath() {
    let catId = UUID()
    let categories = Categories(from: [Category(id: catId, name: "Groceries")])

    var draft = support.makeExpenseDraft()
    draft.categoryId = catId
    draft.categoryText = "groc"

    draft.normaliseCategoryText(using: categories)

    #expect(draft.categoryId == catId)
    #expect(draft.categoryText == "Groceries")
  }

  // swiftlint:disable:next attributes
  @Test func unknownCategoryIdClearsBothFields() {
    let missingId = UUID()
    let categories = Categories(from: [])

    var draft = support.makeExpenseDraft()
    draft.categoryId = missingId
    draft.categoryText = "Something"

    draft.normaliseCategoryText(using: categories)

    #expect(draft.categoryId == nil)
    #expect(draft.categoryText.isEmpty)
  }

  // Clearing the field to empty must remove the category even when the id
  // still resolves — otherwise normalise rewrites the canonical path back
  // and there is no way to remove a category from the leg.
  // swiftlint:disable:next attributes
  @Test func emptyTextRemovesResolvableCategory() {
    let catId = UUID()
    let categories = Categories(from: [Category(id: catId, name: "Groceries")])

    var draft = support.makeExpenseDraft()
    draft.categoryId = catId
    draft.categoryText = ""

    draft.normaliseCategoryText(using: categories)

    #expect(draft.categoryId == nil)
    #expect(draft.categoryText.isEmpty)
  }

  // Whitespace-only text is treated as empty: it removes the category.
  // swiftlint:disable:next attributes
  @Test func whitespaceTextRemovesResolvableCategory() {
    let catId = UUID()
    let categories = Categories(from: [Category(id: catId, name: "Groceries")])

    var draft = support.makeExpenseDraft()
    draft.categoryId = catId
    draft.categoryText = "   "

    draft.normaliseCategoryText(using: categories)

    #expect(draft.categoryId == nil)
    #expect(draft.categoryText.isEmpty)
  }

  // Per-leg counterpart: clearing a leg's field removes its category even
  // when the id still resolves.
  // swiftlint:disable:next attributes
  @Test func emptyLegTextRemovesResolvableCategory() {
    let catId = UUID()
    let categories = Categories(from: [Category(id: catId, name: "Groceries")])

    var draft = support.makeExpenseDraft()
    draft.legDrafts[0].categoryId = catId
    draft.legDrafts[0].categoryText = ""

    draft.normaliseLegCategoryText(at: 0, using: categories)

    #expect(draft.legDrafts[0].categoryId == nil)
    #expect(draft.legDrafts[0].categoryText.isEmpty)
  }

  // swiftlint:disable:next attributes
  @Test func nilCategoryIdClearsText() {
    let categories = Categories(from: [Category(id: UUID(), name: "Groceries")])

    var draft = support.makeExpenseDraft()
    draft.categoryId = nil
    draft.categoryText = "partial input"

    draft.normaliseCategoryText(using: categories)

    #expect(draft.categoryId == nil)
    #expect(draft.categoryText.isEmpty)
  }

  // swiftlint:disable:next attributes
  @Test func commitHighlightedAdoptsSuggestion() {
    let catId = UUID()
    let categories = Categories(from: [Category(id: catId, name: "Groceries")])
    let suggestion = CategorySuggestion(id: catId, path: "Groceries")

    var draft = support.makeExpenseDraft()
    draft.categoryText = "groc"

    draft.commitHighlightedCategoryOrNormalise(
      highlighted: suggestion, using: categories)

    #expect(draft.categoryId == catId)
    #expect(draft.categoryText == "Groceries")
  }

  // swiftlint:disable:next attributes
  @Test func commitFallsBackToNormaliseWhenNothingHighlighted() {
    let catId = UUID()
    let categories = Categories(from: [Category(id: catId, name: "Groceries")])

    var draft = support.makeExpenseDraft()
    draft.categoryId = catId
    draft.categoryText = "groc"

    draft.commitHighlightedCategoryOrNormalise(
      highlighted: nil, using: categories)

    #expect(draft.categoryId == catId)
    #expect(draft.categoryText == "Groceries")
  }

  // swiftlint:disable:next attributes
  @Test func commitFallsBackToNormaliseClearsUnknownText() {
    let categories = Categories(from: [])

    var draft = support.makeExpenseDraft()
    draft.categoryText = "Made up"

    draft.commitHighlightedCategoryOrNormalise(
      highlighted: nil, using: categories)

    #expect(draft.categoryId == nil)
    #expect(draft.categoryText.isEmpty)
  }

  // swiftlint:disable:next attributes
  @Test func commitHighlightedLegAdoptsSuggestion() {
    let catId = UUID()
    let categories = Categories(from: [Category(id: catId, name: "Groceries")])
    let suggestion = CategorySuggestion(id: catId, path: "Groceries")

    var draft = support.makeExpenseDraft()
    draft.legDrafts[0].categoryText = "groc"

    draft.commitHighlightedLegCategoryOrNormalise(
      at: 0, highlighted: suggestion, using: categories)

    #expect(draft.legDrafts[0].categoryId == catId)
    #expect(draft.legDrafts[0].categoryText == "Groceries")
  }

  // swiftlint:disable:next attributes
  @Test func commitFallsBackToLegNormaliseWhenNothingHighlighted() {
    let categories = Categories(from: [])

    var draft = support.makeExpenseDraft()
    draft.legDrafts[0].categoryText = "Made up"

    draft.commitHighlightedLegCategoryOrNormalise(
      at: 0, highlighted: nil, using: categories)

    #expect(draft.legDrafts[0].categoryId == nil)
    #expect(draft.legDrafts[0].categoryText.isEmpty)
  }

  // Per https://github.com/moolah-rocks/moolah-native/issues/509 reopening:
  // `commitCategorySelection(id:path:)` must set both fields in a single
  // mutation so call sites doing `draft.commitCategorySelection(...)`
  // through a `@Binding` produce one read-modify-write rather than two
  // snapshot-based writes that clobber each other.
  // swiftlint:disable:next attributes
  @Test func commitCategorySelectionSetsBothFields() {
    let catId = UUID()

    var draft = support.makeExpenseDraft()
    draft.categoryId = nil
    draft.categoryText = "groc"

    draft.commitCategorySelection(id: catId, path: "Groceries")

    #expect(draft.categoryId == catId)
    #expect(draft.categoryText == "Groceries")
  }

  // Per-leg counterpart to `commitCategorySelectionSetsBothFields` —
  // the per-leg call sites in `TransactionDetailLegRow` and
  // `TransactionDetailLegCategoryOverlay` rely on the single-mutation
  // guarantee.
  // swiftlint:disable:next attributes
  @Test func commitLegCategorySelectionSetsBothFieldsAtIndex() {
    let catId = UUID()

    var draft = support.makeExpenseDraft()
    draft.legDrafts[0].categoryId = nil
    draft.legDrafts[0].categoryText = "gym"

    draft.commitLegCategorySelection(at: 0, id: catId, path: "Gym")

    #expect(draft.legDrafts[0].categoryId == catId)
    #expect(draft.legDrafts[0].categoryText == "Gym")
  }
}
