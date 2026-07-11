import Foundation
import GRDB
import Testing

@testable import Moolah

// These assignment persistence cases share save/create helpers and cover one owner-pruning contract.
@Suite("Tax owner assignment persistence")
@MainActor
struct TaxOwnerAssignmentPersistenceTests {  // swiftlint:disable:this type_body_length
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

  @Test("account tax owner assignment store loads owners and prunes stale selection")
  func accountTaxOwnerAssignmentStoreLoadsAndPrunesSelection() async throws {
    let (backend, _) = try TestBackend.create()
    let validOwner = TaxOwner(id: UUID(), name: "Alex")
    let deletedOwnerId = UUID()
    _ = try await backend.taxOwners.create(validOwner)
    let store = AccountTaxOwnerAssignmentStore(
      selectedOwnerIds: [deletedOwnerId, validOwner.id])

    await store.loadOwners(from: backend.taxOwners)

    #expect(store.owners == [validOwner])
    #expect(store.selectedOwnerIds == [validOwner.id])
    #expect(store.errorMessage == nil)
  }

  @Test("account tax owner assignment store surfaces load failures")
  func accountTaxOwnerAssignmentStoreSurfacesLoadFailures() async {
    let selectedOwnerIds = [UUID()]
    let store = AccountTaxOwnerAssignmentStore(selectedOwnerIds: selectedOwnerIds)

    await store.loadOwners(from: ThrowingTaxOwnerRepository())

    #expect(store.owners.isEmpty)
    #expect(store.selectedOwnerIds == selectedOwnerIds)
    #expect(store.errorMessage == AccountTaxOwnerAssignmentStore.loadErrorMessage)
  }

  @Test("account tax owner assignment store supports flow-specific load copy")
  func accountTaxOwnerAssignmentStoreSupportsFlowSpecificLoadCopy() async {
    let selectedOwnerIds = [UUID()]
    let message = "Couldn't load tax owners. Reopen Create Account and try again."
    let store = AccountTaxOwnerAssignmentStore(
      selectedOwnerIds: selectedOwnerIds,
      loadErrorMessage: message)

    await store.loadOwners(from: ThrowingTaxOwnerRepository())

    #expect(store.owners.isEmpty)
    #expect(store.selectedOwnerIds == selectedOwnerIds)
    #expect(store.errorMessage == message)
  }

  @Test("category tax owner assignment store loads owners and prunes selected category")
  func categoryTaxOwnerAssignmentStoreLoadsAndPrunesSelectedCategory() async throws {
    let (backend, _) = try TestBackend.create()
    let validOwner = TaxOwner(id: UUID(), name: "Alex")
    let deletedOwnerId = UUID()
    _ = try await backend.taxOwners.create(validOwner)
    var selectedCategory = Category(name: "Interest")
    selectedCategory.taxOwnerIds = [deletedOwnerId, validOwner.id]
    let store = CategoryTaxOwnerAssignmentStore()
    store.select(selectedCategory)

    await store.loadOwners(from: backend.taxOwners)

    #expect(store.owners == [validOwner])
    #expect(store.selectedCategory?.taxOwnerIds == [validOwner.id])
    #expect(store.errorMessage == nil)
  }

  @Test("category tax owner assignment store surfaces load failures")
  func categoryTaxOwnerAssignmentStoreSurfacesLoadFailures() async {
    var selectedCategory = Category(name: "Interest")
    selectedCategory.taxOwnerIds = [UUID()]
    let store = CategoryTaxOwnerAssignmentStore()
    store.select(selectedCategory)

    await store.loadOwners(from: ThrowingTaxOwnerRepository())

    #expect(store.owners.isEmpty)
    #expect(store.selectedCategory?.taxOwnerIds == selectedCategory.taxOwnerIds)
    #expect(store.errorMessage == CategoryTaxOwnerAssignmentStore.loadErrorMessage)
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

struct ThrowingTaxOwnerRepository: TaxOwnerRepository {
  func fetchAll() async throws -> [TaxOwner] {
    throw BackendError.notFound("tax owners")
  }

  func observeAll() -> AsyncStream<[TaxOwner]> {
    AsyncStream { $0.finish() }
  }

  func observeErrors() -> AsyncStream<any Error> {
    AsyncStream { $0.finish() }
  }

  func create(_ owner: TaxOwner) async throws -> TaxOwner {
    throw BackendError.notFound("tax owner create")
  }

  func update(_ owner: TaxOwner) async throws -> TaxOwner {
    throw BackendError.notFound("tax owner update")
  }

  func delete(id: UUID) async throws {
    throw BackendError.notFound("tax owner delete")
  }
}

@Suite("Default tax owner assignment persistence")
struct DefaultTaxOwnerPersistenceTests {
  @Test("retired implicit default owner is not recreated")
  func retiredImplicitDefaultOwnerIsNotRecreated() async throws {
    let database = try ProfileDatabase.openInMemory()
    let implicitDefaultOwnerId = UUID()
    let replacementDefaultOwnerId = UUID()
    let repository = GRDBTaxOwnerRepository(
      database: database,
      defaultTaxOwnerId: implicitDefaultOwnerId,
      implicitDefaultTaxOwnerId: implicitDefaultOwnerId)
    #expect(try await repository.fetchAll().map(\.id) == [implicitDefaultOwnerId])
    _ = try await repository.create(
      TaxOwner(id: replacementDefaultOwnerId, name: "Replacement default"))

    repository.updateDefaultTaxOwnerId(replacementDefaultOwnerId)
    try await repository.delete(id: implicitDefaultOwnerId)
    try await database.write { database in
      try DeletionJournal.clearDataDeletion(
        recordName: TaxOwnerRow.recordName(for: implicitDefaultOwnerId),
        in: database)
    }

    #expect(try await repository.fetchAll().map(\.id) == [replacementDefaultOwnerId])
  }

  @Test("deleting bootstrapped default tax owner removes the stored row")
  func deletingBootstrappedDefaultTaxOwnerRemovesStoredRow() async throws {
    let database = try ProfileDatabase.openInMemory()
    let ownerId = UUID()
    let repository = GRDBTaxOwnerRepository(database: database, defaultTaxOwnerId: ownerId)
    try repository.bootstrapImplicitDefaultOwner()
    #expect(try await repository.fetchAll().map(\.id) == [ownerId])

    try await repository.delete(id: ownerId)
    try await database.write { database in
      try DeletionJournal.clearDataDeletion(
        recordName: TaxOwnerRow.recordName(for: ownerId), in: database)
    }

    #expect(try await repository.fetchAll().isEmpty)
    #expect(try repository.allRowIdsSync().isEmpty)
  }
}
