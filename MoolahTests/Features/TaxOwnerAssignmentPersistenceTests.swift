import Foundation
import Testing

@testable import Moolah

@Suite("Tax owner assignment persistence")
@MainActor
struct TaxOwnerAssignmentPersistenceTests {
  @Test("account save helper prunes stale owners at the save callsite")
  func accountSavePrunesStaleOwners() {
    let validOwner = TaxOwner(id: UUID(), name: "Alex")
    let deletedOwnerId = UUID()
    let account = Account(
      name: "Joint Account",
      type: .bank,
      instrument: .defaultTestInstrument)

    let updated = EditAccountView.updatedAccount(
      from: account,
      draft: EditAccountDraft(
        name: "Joint Account",
        type: .bank,
        instrument: .defaultTestInstrument,
        isHidden: false,
        valuationMode: .recordedValue,
        taxOwnerIds: [deletedOwnerId, validOwner.id]),
      validOwners: [validOwner])

    #expect(updated.taxOwnerIds == [validOwner.id])
  }

  @Test("category save decision discards empty or reverted edits")
  func categorySaveDecisionDiscardsInvalidOrRevertedEdits() {
    let category = Category(name: "Interest")

    #expect(
      CategoryDetailView.saveDecision(
        from: category,
        name: "",
        isTaxReportable: false,
        taxOwnerIds: []) == .discardPendingUpdate)
    #expect(
      CategoryDetailView.saveDecision(
        from: category,
        name: "Interest",
        isTaxReportable: false,
        taxOwnerIds: []) == .discardPendingUpdate)
  }

  @Test("category edit and create callsites prune stale owners")
  func categoryCallsitesPruneStaleOwners() throws {
    let validOwner = TaxOwner(id: UUID(), name: "Alex")
    let deletedOwnerId = UUID()
    let category = Category(name: "Interest")

    let editDecision = CategoryDetailView.saveDecision(
      from: category,
      name: "Interest Income",
      isTaxReportable: true,
      taxOwnerIds: [deletedOwnerId, validOwner.id],
      validOwners: [validOwner])
    guard case .update(let edited) = editDecision else {
      Issue.record("Expected edited category update")
      return
    }
    #expect(edited.taxOwnerIds == [validOwner.id])

    let created = CreateCategorySheet.category(
      name: "Interest",
      parentId: nil,
      isTaxReportable: true,
      taxOwnerIds: [deletedOwnerId, validOwner.id],
      validOwners: [validOwner])
    #expect(created.taxOwnerIds == [validOwner.id])
  }

  @Test("account store update persists zero one and many tax owners")
  func accountStorePersistsTaxOwnerSelection() async throws {
    let (backend, _) = try TestBackend.create()
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForFirstEmission()
    let ownerA = UUID()
    let ownerB = UUID()
    var account = try await store.create(
      Account(name: "Joint Account", type: .bank, instrument: .defaultTestInstrument))

    for owners in [[], [ownerA], [ownerA, ownerB]] {
      account.taxOwnerIds = owners
      _ = try await store.update(account)

      let persisted = try #require(try await backend.accounts.fetchAll().first)
      #expect(persisted.taxOwnerIds == owners)
    }
  }

  @Test("account repository create and update trim newlines from names")
  func accountRepositoryTrimsNewlinesFromNames() async throws {
    let (backend, _) = try TestBackend.create()
    let account = try await backend.accounts.create(
      Account(
        name: "\n  Joint Account  \n",
        type: .bank,
        instrument: .defaultTestInstrument))
    #expect(account.name == "Joint Account")

    var updated = account
    updated.name = "\n  Updated Account  \n"
    let saved = try await backend.accounts.update(updated)
    #expect(saved.name == "Updated Account")

    let persisted = try #require(
      try await backend.accounts.fetchAll().first { $0.id == account.id })
    #expect(persisted.name == "Updated Account")
  }

  @Test("account repository rejects newline-only names")
  func accountRepositoryRejectsNewlineOnlyNames() async throws {
    let (backend, _) = try TestBackend.create()
    let account = try await backend.accounts.create(
      Account(
        name: "Joint Account",
        type: .bank,
        instrument: .defaultTestInstrument))

    await #expect(throws: BackendError.self) {
      try await backend.accounts.create(
        Account(
          name: "\n\t\n",
          type: .bank,
          instrument: .defaultTestInstrument))
    }

    var update = account
    update.name = "\n\t\n"
    await #expect(throws: BackendError.self) {
      try await backend.accounts.update(update)
    }

    let persisted = try #require(
      try await backend.accounts.fetchAll().first { $0.id == account.id })
    #expect(persisted.name == "Joint Account")
  }

  @Test("account store create and update trim and reject newline names")
  func accountStoreTrimsAndRejectsNewlineNames() async throws {
    let (backend, _) = try TestBackend.create()
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForFirstEmission()

    let account = try await store.create(
      Account(
        name: "\n  Joint Account  \n",
        type: .bank,
        instrument: .defaultTestInstrument))
    #expect(account.name == "Joint Account")

    var renamed = account
    renamed.name = "\n  Updated Account  \n"
    let updated = try await store.update(renamed)
    #expect(updated.name == "Updated Account")

    await #expect(throws: BackendError.self) {
      try await store.create(
        Account(
          name: "\n\t\n",
          type: .bank,
          instrument: .defaultTestInstrument))
    }
    #expect(store.error != nil)

    var blank = updated
    blank.name = "\n\t\n"
    await #expect(throws: BackendError.self) {
      try await store.update(blank)
    }
    #expect(store.error != nil)
    let persisted = try #require(
      try await backend.accounts.fetchAll().first { $0.id == account.id })
    #expect(persisted.name == "Updated Account")
  }

  @Test("category repository create and update trim and reject newline names")
  func categoryRepositoryTrimsAndRejectsNewlineNames() async throws {
    let (backend, _) = try TestBackend.create()
    let created = try await backend.categories.create(
      Category(name: "\n  Interest  \n"))
    #expect(created.name == "Interest")

    var renamed = created
    renamed.name = "\n  Dividends  \n"
    let updated = try await backend.categories.update(renamed)
    #expect(updated.name == "Dividends")

    await #expect(throws: BackendError.self) {
      try await backend.categories.create(Category(name: "\n\t\n"))
    }

    var blank = updated
    blank.name = "\n\t\n"
    await #expect(throws: BackendError.self) {
      try await backend.categories.update(blank)
    }

    let persisted = try #require(
      try await backend.categories.fetchAll().first { $0.id == created.id })
    #expect(persisted.name == "Dividends")
  }

  @Test("category store create and update persist tax treatment and owner override")
  func categoryStorePersistsTaxFields() async throws {
    let (backend, _) = try TestBackend.create()
    let store = CategoryStore(repository: backend.categories)
    try await store.waitForFirstEmission()
    let owner = UUID()

    let created = try #require(
      await store.create(
        CreateCategorySheet.category(name: "Interest", parentId: nil)))
    #expect(created.isTaxReportable == false)
    #expect(created.taxOwnerIds.isEmpty)

    let updated = CategoryDetailView.updatedCategory(
      from: created,
      name: "Interest",
      isTaxReportable: true,
      taxOwnerIds: [owner])
    _ = await store.update(updated)

    let persisted = try #require(try await backend.categories.fetchAll().first)
    #expect(persisted.isTaxReportable == true)
    #expect(persisted.taxOwnerIds == [owner])

    let nonReportable = CategoryDetailView.updatedCategory(
      from: persisted,
      name: "Interest",
      isTaxReportable: false,
      taxOwnerIds: [owner])
    _ = await store.update(nonReportable)

    let refetched = try #require(try await backend.categories.fetchAll().first)
    #expect(refetched.isTaxReportable == false)
    #expect(refetched.taxOwnerIds.isEmpty)
  }
}
