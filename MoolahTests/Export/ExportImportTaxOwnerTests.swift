import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("Export/Import Tax Owners")
@MainActor
struct ExportImportTaxOwnerTests {
  private let instrument = Instrument.defaultTestInstrument

  private struct Seed {
    let backend: CloudKitBackend
    let defaultOwner: TaxOwner
    let trustOwner: TaxOwner
  }

  @Test("tax owners, default owner, names, kinds, and assignments round-trip")
  func taxOwnershipRoundTrip() async throws {
    let sourceProfile = Profile(
      label: "Household",
      currencyCode: instrument.id,
      financialYearStartMonth: 7)
    let seed = try await makeSeed(profile: sourceProfile)

    let fileURL = makeTempFileURL()
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let coordinator = ExportCoordinator()
    try await coordinator.exportToFile(
      url: fileURL,
      backend: seed.backend,
      profile: sourceProfile)

    let exported = try ExportDocumentCodec().decode(Data(contentsOf: fileURL))
    #expect(exported.defaultTaxOwnerId == seed.defaultOwner.id)
    #expect(Set(exported.taxOwners) == [seed.defaultOwner, seed.trustOwner])

    let containerManager = try ProfileContainerManager.forTesting()
    let syncCoordinator = SyncCoordinator(containerManager: containerManager)
    let profileStore = try makeProfileStore(
      containerManager: containerManager,
      syncCoordinator: syncCoordinator)
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let importedProfileId = try await coordinator.importNewProfileFromFile(
      url: fileURL,
      profileStore: profileStore,
      containerManager: containerManager,
      syncCoordinator: syncCoordinator,
      instrumentRegistrar: registry)

    let importedProfile = try #require(
      profileStore.profiles.first { $0.id == importedProfileId })
    #expect(importedProfile.defaultTaxOwnerId == seed.defaultOwner.id)
    #expect(
      importedProfile.defaultTaxOwnerId
        != ProfileIndexSchema.defaultTaxOwnerId(for: importedProfileId))
    #expect(
      Set(coordinator.lastRecordIDsQueuedForUpload.map(\.recordName)).isSuperset(of: [
        TaxOwnerRow.recordName(for: seed.defaultOwner.id),
        TaxOwnerRow.recordName(for: seed.trustOwner.id),
      ]))
    let persistedProfile = try await containerManager.profileIndexRepository.profile(
      forID: importedProfileId)
    #expect(persistedProfile?.defaultTaxOwnerId == seed.defaultOwner.id)

    try await verifyImportedData(
      profile: importedProfile,
      containerManager: containerManager,
      registry: registry,
      seed: seed)
  }

  @Test("legacy assignments without owner metadata inherit the imported profile default")
  func legacyAssignmentsWithoutOwnerMetadataInheritDefault() async throws {
    let missingOwnerId = UUID()
    let legacy = ExportedData(
      accounts: [
        Account(
          name: "Legacy Account",
          type: .bank,
          instrument: instrument,
          taxOwnerIds: [missingOwnerId])
      ],
      categories: [
        Category(name: "Legacy Category", taxOwnerIds: [missingOwnerId])
      ],
      earmarks: [],
      earmarkBudgets: [:],
      transactions: [],
      investmentValues: [:])
    let database = try ProfileDatabase.openInMemory()

    _ = try await CloudKitDataImporter(database: database, currencyCode: instrument.id)
      .importData(legacy)

    let ownerReferenceCounts = try await database.read { database in
      (
        accounts: try AccountTaxOwnerRow.fetchCount(database),
        categories: try CategoryTaxOwnerRow.fetchCount(database)
      )
    }
    #expect(ownerReferenceCounts.accounts == 0)
    #expect(ownerReferenceCounts.categories == 0)
    let importedRows = try await database.read { database in
      (
        account: try AccountRow.fetchOne(database),
        category: try CategoryRow.fetchOne(database)
      )
    }
    let importedAccount = try #require(importedRows.account)
    let importedCategory = try #require(importedRows.category)
    #expect(TaxOwnerIDListCoding.decode(importedAccount.taxOwnerIdsEncoded).isEmpty)
    #expect(TaxOwnerIDListCoding.decode(importedCategory.taxOwnerIdsEncoded).isEmpty)
  }

  @Test("import transaction rolls back tax ownership when a later write fails")
  func importTransactionRollsBackTaxOwnership() async throws {
    let owner = TaxOwner(name: "Rollback Owner")
    let database = try ProfileDatabase.openInMemory()
    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TEMP TRIGGER fail_account_import
          BEFORE INSERT ON account
          BEGIN
            SELECT RAISE(ABORT, 'forced import failure');
          END;
          """)
    }
    let exported = ExportedData(
      taxOwners: [owner],
      accounts: [
        Account(
          name: "Fails",
          type: .bank,
          instrument: instrument,
          taxOwnerIds: [owner.id])
      ],
      categories: [Category(name: "Written First", taxOwnerIds: [owner.id])],
      earmarks: [],
      earmarkBudgets: [:],
      transactions: [],
      investmentValues: [:])

    await #expect(throws: (any Error).self) {
      _ = try await CloudKitDataImporter(database: database, currencyCode: instrument.id)
        .importData(exported)
    }
    let counts = try await database.read { database in
      (
        owners: try TaxOwnerRow.fetchCount(database),
        categories: try CategoryRow.fetchCount(database),
        categoryOwners: try CategoryTaxOwnerRow.fetchCount(database),
        accounts: try AccountRow.fetchCount(database)
      )
    }
    #expect(counts.owners == 0)
    #expect(counts.categories == 0)
    #expect(counts.categoryOwners == 0)
    #expect(counts.accounts == 0)
  }

  @Test("legacy export without tax-owner metadata still decodes")
  func legacyExportDecodesWithoutTaxOwnerMetadata() throws {
    let legacyJSON = """
      {
        "version": 1,
        "exportedAt": "2026-01-01T00:00:00Z",
        "profileLabel": "Legacy",
        "currencyCode": "AUD",
        "financialYearStartMonth": 7,
        "instruments": [],
        "accounts": [],
        "accountGroups": [],
        "categories": [],
        "earmarks": [],
        "earmarkBudgets": [],
        "transactions": [],
        "investmentValues": []
      }
      """

    let exported = try ExportDocumentCodec().decode(Data(legacyJSON.utf8))
    #expect(exported.defaultTaxOwnerId == nil)
    #expect(exported.taxOwners.isEmpty)
  }

  private func makeBackend(profile: Profile) throws -> CloudKitBackend {
    let database = try ProfileDatabase.openInMemory()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    return CloudKitBackend(
      database: database,
      instrument: instrument,
      profileLabel: profile.label,
      defaultTaxOwnerId: profile.defaultTaxOwnerId,
      implicitDefaultTaxOwnerId: profile.defaultTaxOwnerId,
      conversionService: FakeConversionService.fixedRates([:]),
      instrumentRegistry: registry)
  }

  private func verifyImportedData(
    profile: Profile,
    containerManager: ProfileContainerManager,
    registry: GRDBInstrumentRegistryRepository,
    seed: Seed
  ) async throws {
    let imported = CloudKitBackend(
      database: try containerManager.database(for: profile.id),
      instrument: instrument,
      profileLabel: profile.label,
      defaultTaxOwnerId: profile.defaultTaxOwnerId,
      implicitDefaultTaxOwnerId: ProfileIndexSchema.defaultTaxOwnerId(for: profile.id),
      conversionService: FakeConversionService.fixedRates([:]),
      instrumentRegistry: registry)
    #expect(Set(try await imported.taxOwners.fetchAll()) == [seed.defaultOwner, seed.trustOwner])
    #expect(
      try await imported.accounts.fetchAll().first?.taxOwnerIds == [
        seed.defaultOwner.id, seed.trustOwner.id,
      ])
    #expect(try await imported.categories.fetchAll().first?.taxOwnerIds == [seed.trustOwner.id])
  }

  private func makeSeed(profile: Profile) async throws -> Seed {
    let backend = try makeBackend(profile: profile)
    let defaultOwner = TaxOwner(
      id: profile.defaultTaxOwnerId,
      name: "Alex",
      kind: .individual)
    let trustOwner = TaxOwner(name: "Family Trust", kind: .trust)
    _ = try await backend.taxOwners.update(defaultOwner)
    _ = try await backend.taxOwners.create(trustOwner)
    _ = try await backend.accounts.create(
      Account(
        name: "Joint Brokerage",
        type: .investment,
        instrument: instrument,
        taxOwnerIds: [defaultOwner.id, trustOwner.id]),
      openingBalance: nil)
    _ = try await backend.categories.create(
      Category(
        name: "Distributions",
        isTaxReportable: true,
        taxOwnerIds: [trustOwner.id]))
    return Seed(backend: backend, defaultOwner: defaultOwner, trustOwner: trustOwner)
  }

  private func makeProfileStore(
    containerManager: ProfileContainerManager,
    syncCoordinator: SyncCoordinator? = nil
  ) throws -> ProfileStore {
    let defaults = try #require(UserDefaults(suiteName: "test-\(UUID().uuidString)"))
    return ProfileStore(
      defaults: defaults,
      containerManager: containerManager,
      syncCoordinator: syncCoordinator)
  }

  private func makeTempFileURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("moolah-tax-owner-test-\(UUID().uuidString).json")
  }
}
