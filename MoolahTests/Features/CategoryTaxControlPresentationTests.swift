import Foundation
import Testing

@testable import Moolah

@Suite("Category tax control presentation")
@MainActor
struct CategoryTaxControlPresentationTests {
  @Test("category owner override visibility follows reportable owner and error state")
  func categoryOwnerOverrideVisibilityRules() {
    #expect(
      CategoryTaxOwnerOverridePresentation(
        isTaxReportable: false,
        ownerCount: 2,
        errorMessage: nil
      ).isVisible == false)
    #expect(
      CategoryTaxOwnerOverridePresentation(
        isTaxReportable: true,
        ownerCount: 1,
        errorMessage: nil
      ).isVisible == false)
    #expect(
      CategoryTaxOwnerOverridePresentation(
        isTaxReportable: true,
        ownerCount: 2,
        errorMessage: nil
      ).showsControls)
    #expect(
      CategoryTaxOwnerOverridePresentation(
        isTaxReportable: true,
        ownerCount: 0,
        errorMessage: "Load failed"
      ).showsUnavailableMessage)
  }

  @Test("category override copy describes account fallback without inheritance")
  func categoryOverrideCopyDescribesAccountFallback() {
    #expect(
      CategoryTaxOwnerOverridePresentation.emptySelectionSummary
        == "Uses transaction account tax ownership")
    #expect(
      CategoryTaxOwnerOverridePresentation.clearSelectionLabel
        == "Use account/profile default")
    #expect(CategoryTaxOwnerOverridePresentation.footer.contains("transaction account"))
    #expect(CategoryTaxOwnerOverridePresentation.footer.contains("profile default"))
    #expect(
      !CategoryTaxOwnerOverridePresentation.footer.localizedCaseInsensitiveContains("inherit"))
    #expect(!CategoryTaxOwnerOverridePresentation.footer.localizedCaseInsensitiveContains("parent"))
  }

  @Test("create and edit category names trim newlines and reject blank names")
  func categoryNameValidationTrimsAndRejectsBlankNames() throws {
    #expect(CreateCategorySheet.isCreateDisabled(name: "\n\t\n", isSubmitting: false))
    #expect(CreateCategorySheet.isCreateDisabled(name: "Interest", isSubmitting: true))

    let created = CreateCategorySheet.category(name: "\n  Interest  \n", parentId: nil)
    #expect(created.name == "Interest")

    let blankDecision = CategoryDetailView.saveDecision(
      from: Category(name: "Interest"),
      name: "\n\t\n",
      isTaxReportable: false,
      taxOwnerIds: [])
    #expect(blankDecision == .discardPendingUpdate)

    let updateDecision = CategoryDetailView.saveDecision(
      from: Category(name: "Interest"),
      name: "\n  Interest Income  \n",
      isTaxReportable: false,
      taxOwnerIds: [])
    guard case .update(let updated) = updateDecision else {
      Issue.record("Expected edited category update")
      return
    }
    #expect(updated.name == "Interest Income")
  }

  @Test("category tax owner retry success clears errors and prunes selection")
  func categoryTaxOwnerRetrySuccessClearsErrorsAndPrunesSelection() {
    let owner = TaxOwner(id: UUID(), name: "Alex")
    let removedOwnerId = UUID()
    let category = Category(
      name: "Interest",
      isTaxReportable: true,
      taxOwnerIds: [removedOwnerId, owner.id])

    let state = CategoriesView.taxOwnerLoadSuccess(
      owners: [owner],
      selectedCategory: category)

    #expect(state.owners == [owner])
    #expect(state.errorMessage == nil)
    #expect(state.selectedCategory?.taxOwnerIds == [owner.id])
  }

  @Test("category tax owner retry failure preserves selection and shows error")
  func categoryTaxOwnerRetryFailurePreservesSelectionAndShowsError() {
    let ownerId = UUID()
    let category = Category(
      name: "Interest",
      isTaxReportable: true,
      taxOwnerIds: [ownerId])

    let state = CategoriesView.taxOwnerLoadFailure(selectedCategory: category)

    #expect(state.errorMessage == CategoriesView.taxOwnerLoadErrorMessage)
    #expect(state.selectedCategory?.taxOwnerIds == [ownerId])
  }
  @Test("delete confirmation discards pending save before deleting")
  func deleteConfirmationDiscardsPendingSaveBeforeDeleting() {
    let categoryId = UUID()
    let replacementId = UUID()
    var events: [String] = []

    CategoryDetailView.confirmDelete(
      categoryId: categoryId,
      replacementId: replacementId,
      onDiscardPendingUpdate: { events.append("discard") },
      onDelete: { deletedId, deletedReplacementId in
        #expect(deletedId == categoryId)
        #expect(deletedReplacementId == replacementId)
        events.append("delete")
      })

    #expect(events == ["discard", "delete"])
  }
}
