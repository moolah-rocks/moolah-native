import Foundation
import Testing

@testable import Moolah

@Suite("Tax owner assignment controls")
@MainActor
struct TaxOwnerAssignmentControlsTests {
  @Test("owner controls are hidden until a second owner exists")
  func ownerControlsRequireMultipleOwners() {
    let defaultOwner = TaxOwner(id: UUID(), name: "Alex")
    let spouse = TaxOwner(id: UUID(), name: "Sam")

    #expect(
      TaxOwnerAssignmentState(
        owners: [], defaultOwnerId: defaultOwner.id, selectedOwnerIds: []
      ).showsControls == false)
    #expect(
      TaxOwnerAssignmentState(
        owners: [defaultOwner], defaultOwnerId: defaultOwner.id, selectedOwnerIds: []
      ).showsControls == false)
    #expect(
      TaxOwnerAssignmentState(
        owners: [defaultOwner, spouse], defaultOwnerId: defaultOwner.id, selectedOwnerIds: []
      ).showsControls == true)
  }

  @Test("empty tax owner selection means profile default")
  func emptySelectionSummarisesProfileDefault() {
    let defaultOwner = TaxOwner(id: UUID(), name: "Alex")
    let spouse = TaxOwner(id: UUID(), name: "Sam")
    let state = TaxOwnerAssignmentState(
      owners: [defaultOwner, spouse],
      defaultOwnerId: defaultOwner.id,
      selectedOwnerIds: [])

    #expect(state.summary == "Profile default: Alex")
  }

  @Test("explicit selections summarise owner names in owner order")
  func explicitSelectionSummarisesOwnersInDisplayOrder() {
    let defaultOwner = TaxOwner(id: UUID(), name: "Alex")
    let spouse = TaxOwner(id: UUID(), name: "Sam")
    let trust = TaxOwner(id: UUID(), name: "Family Trust", kind: .trust)
    let state = TaxOwnerAssignmentState(
      owners: [defaultOwner, spouse, trust],
      defaultOwnerId: defaultOwner.id,
      selectedOwnerIds: [trust.id, spouse.id])

    #expect(state.summary == "Sam, Family Trust")
  }

  @Test("selecting and clearing owners preserves the visible owner order")
  func selectionMutationPreservesOwnerOrder() {
    let defaultOwner = TaxOwner(id: UUID(), name: "Alex")
    let spouse = TaxOwner(id: UUID(), name: "Sam")
    let trust = TaxOwner(id: UUID(), name: "Family Trust", kind: .trust)
    let state = TaxOwnerAssignmentState(
      owners: [defaultOwner, spouse, trust],
      defaultOwnerId: defaultOwner.id,
      selectedOwnerIds: [trust.id])

    let afterSelectingSpouse = state.selection(setting: spouse.id, isSelected: true)
    #expect(afterSelectingSpouse == [spouse.id, trust.id])

    let afterClearingTrust = TaxOwnerAssignmentState(
      owners: [defaultOwner, spouse, trust],
      defaultOwnerId: defaultOwner.id,
      selectedOwnerIds: afterSelectingSpouse
    ).selection(setting: trust.id, isSelected: false)
    #expect(afterClearingTrust == [spouse.id])
  }

  @Test("account save draft preserves zero one and many owners")
  func accountSaveDraftPreservesOwnerSelection() {
    let ownerA = UUID()
    let ownerB = UUID()
    let account = Account(
      name: "Joint Account",
      type: .bank,
      instrument: .defaultTestInstrument)

    #expect(
      EditAccountView.updatedAccount(
        from: account,
        draft: EditAccountDraft(
          name: "Joint Account",
          type: .bank,
          instrument: .defaultTestInstrument,
          isHidden: false,
          taxOwnerIds: [])
      ).taxOwnerIds.isEmpty)
    #expect(
      EditAccountView.updatedAccount(
        from: account,
        draft: EditAccountDraft(
          name: "Joint Account",
          type: .bank,
          instrument: .defaultTestInstrument,
          isHidden: false,
          taxOwnerIds: [ownerA])
      ).taxOwnerIds == [ownerA])
    #expect(
      EditAccountView.updatedAccount(
        from: account,
        draft: EditAccountDraft(
          name: "Joint Account",
          type: .bank,
          instrument: .defaultTestInstrument,
          isHidden: false,
          taxOwnerIds: [ownerA, ownerB])
      ).taxOwnerIds == [ownerA, ownerB])
  }

  @Test("account save draft trims newlines from names")
  func accountSaveDraftTrimsNewlinesFromNames() {
    let account = Account(
      name: "Joint Account",
      type: .bank,
      instrument: .defaultTestInstrument)

    let updated = EditAccountView.updatedAccount(
      from: account,
      draft: EditAccountDraft(
        name: "\n  Joint Account  \n",
        type: .bank,
        instrument: .defaultTestInstrument,
        isHidden: false,
        taxOwnerIds: []))

    #expect(updated.name == "Joint Account")
  }

  @Test("account edit validation rejects newline-only names and submitting saves")
  func accountEditValidationRejectsBlankAndSubmittingSaves() {
    #expect(EditAccountView.isSaveDisabled(name: "\n\t\n", isSubmitting: false))
    #expect(EditAccountView.isSaveDisabled(name: "Joint Account", isSubmitting: true))
    #expect(!EditAccountView.isSaveDisabled(name: "\n  Joint Account  \n", isSubmitting: false))
  }

  @Test("account create validation rejects blank and submitting creates")
  func accountCreateValidationRejectsBlankAndSubmittingCreates() {
    #expect(
      CreateAccountView.isCreateDisabled(
        name: "\n\t\n",
        type: .bank,
        cryptoWalletAddress: "",
        exchangeToken: "",
        isSubmitting: false))
    #expect(
      CreateAccountView.isCreateDisabled(
        name: "Joint Account",
        type: .bank,
        cryptoWalletAddress: "",
        exchangeToken: "",
        isSubmitting: true))
    #expect(
      !CreateAccountView.isCreateDisabled(
        name: "\n  Joint Account  \n",
        type: .bank,
        cryptoWalletAddress: "",
        exchangeToken: "",
        isSubmitting: false))
  }

  @Test("account create validation accepts type-specific valid inputs")
  func accountCreateValidationAcceptsTypeSpecificValidInputs() {
    #expect(
      !CreateAccountView.isCreateDisabled(
        name: "Wallet",
        type: .crypto,
        cryptoWalletAddress: "0x1111111111111111111111111111111111111111",
        exchangeToken: "",
        isSubmitting: false))
    #expect(
      !CreateAccountView.isCreateDisabled(
        name: "Exchange",
        type: .exchange,
        cryptoWalletAddress: "",
        exchangeToken: "\n  valid-token  \n",
        isSubmitting: false))
  }

  @Test("new category draft defaults to non-reportable without owner override")
  func newCategoryDraftDefaultsToNonReportable() {
    let category = CreateCategorySheet.category(
      name: "Interest",
      parentId: nil)

    #expect(category.name == "Interest")
    #expect(category.isTaxReportable == false)
    #expect(category.taxOwnerIds.isEmpty)
  }

  @Test("category edit draft persists tax treatment and owner override")
  func categoryEditDraftPersistsTaxFields() {
    let owner = UUID()
    let category = Category(name: "Interest")

    let updated = CategoryDetailView.updatedCategory(
      from: category,
      name: "Interest",
      isTaxReportable: true,
      taxOwnerIds: [owner])

    #expect(updated.isTaxReportable == true)
    #expect(updated.taxOwnerIds == [owner])
  }

  @Test("category draft clears owner override when it is not tax reportable")
  func categoryDraftClearsOwnerOverrideWhenNotReportable() {
    let owner = UUID()
    let category = Category(name: "Interest", isTaxReportable: true, taxOwnerIds: [owner])

    let updated = CategoryDetailView.updatedCategory(
      from: category,
      name: "Interest",
      isTaxReportable: false,
      taxOwnerIds: [owner])

    #expect(updated.isTaxReportable == false)
    #expect(updated.taxOwnerIds.isEmpty)
  }

  @Test("category override empty summary does not claim profile default owner")
  func categoryOverrideEmptySummaryDescribesFallbackRule() {
    let defaultOwner = TaxOwner(id: UUID(), name: "Alex")
    let spouse = TaxOwner(id: UUID(), name: "Sam")
    let state = TaxOwnerAssignmentState(
      owners: [defaultOwner, spouse],
      defaultOwnerId: defaultOwner.id,
      selectedOwnerIds: [],
      emptySelectionDescription: "Account/profile default",
      emptySelectionSummary: "Uses transaction account tax ownership")

    #expect(state.summary == "Uses transaction account tax ownership")
  }

  @Test("owner selections prune deleted owner ids in display order")
  func ownerSelectionPrunesDeletedOwnerIds() {
    let ownerA = TaxOwner(id: UUID(), name: "Alex")
    let ownerB = TaxOwner(id: UUID(), name: "Sam")
    let deletedOwnerId = UUID()

    let pruned = TaxOwnerAssignmentState.prunedSelectedOwnerIds(
      [deletedOwnerId, ownerB.id, ownerA.id],
      validOwners: [ownerA, ownerB])

    #expect(pruned == [ownerB.id, ownerA.id])
  }

}
