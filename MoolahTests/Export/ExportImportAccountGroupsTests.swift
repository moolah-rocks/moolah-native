import Foundation
import GRDB
import Testing

@testable import Moolah

/// Round-trips account groups through the JSON export/import pipeline.
/// Groups are a synced, persisted entity; before this they were dropped
/// on export, leaving imported accounts with dangling `groupId`
/// references and no grouping in the sidebar.
@Suite("Export/Import Account Groups")
@MainActor
struct ExportImportAccountGroupsTests {

  private let instrument = Instrument.defaultTestInstrument

  /// The seeded backend plus the two groups it contains, so each test can
  /// assert against the exact group identities it expects to round-trip.
  private struct Seed {
    let backend: CloudKitBackend
    let savings: AccountGroup
    let bills: AccountGroup
  }

  /// Seeds two account groups in the `current` bucket and one account
  /// assigned to the second group, so the round-trip can assert both the
  /// group records and the `Account.groupId` membership survive.
  private func makeSeed() async throws -> Seed {
    let (backend, _) = try TestBackend.create(instrument: instrument)

    let savings = try await backend.accountGroups.create(
      AccountGroup(
        name: "Savings", bucket: .current, instrument: instrument, position: 0,
        isExpandedInSidebar: true)
    )
    let bills = try await backend.accountGroups.create(
      AccountGroup(
        name: "Bills", bucket: .current, instrument: instrument, position: 1)
    )

    _ = try await backend.accounts.create(
      Account(
        name: "Checking", type: .bank, instrument: instrument, groupId: bills.id
      ),
      openingBalance: InstrumentAmount(quantity: dec("500.00"), instrument: instrument)
    )

    return Seed(backend: backend, savings: savings, bills: bills)
  }

  private func makeTempFileURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("moolah-test-\(UUID().uuidString).json")
  }

  @Test("account groups are written to the export file")
  func groupsAreExported() async throws {
    let seed = try await makeSeed()
    let tempURL = makeTempFileURL()
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let profile = Profile(
      label: "Test Profile", currencyCode: instrument.id, financialYearStartMonth: 1)
    let coordinator = ExportCoordinator()
    try await coordinator.exportToFile(url: tempURL, backend: seed.backend, profile: profile)

    let data = try Data(contentsOf: tempURL)
    let decoded = try JSONDecoder.exportDecoder.decode(ExportedData.self, from: data)

    #expect(decoded.accountGroups.count == 2)
    #expect(decoded.accountGroups.contains { $0.id == seed.savings.id })
    #expect(decoded.accountGroups.contains { $0.id == seed.bills.id })
    #expect(decoded.accounts.first?.groupId == seed.bills.id)
  }

  @Test("account groups and membership are restored on import")
  func groupsRoundTrip() async throws {
    let seed = try await makeSeed()
    let tempURL = makeTempFileURL()
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let profile = Profile(
      label: "Test Profile", currencyCode: instrument.id, financialYearStartMonth: 1)
    let coordinator = ExportCoordinator()
    try await coordinator.exportToFile(url: tempURL, backend: seed.backend, profile: profile)

    let freshDatabase = try ProfileDatabase.openInMemory()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let result = try await coordinator.importFromFile(
      url: tempURL, database: freshDatabase, instrumentRegistrar: registry)

    #expect(result.accountGroupCount == 2)

    let cloudBackend = CloudKitBackend(
      database: freshDatabase, instrument: instrument, profileLabel: "Test Profile",
      conversionService: FakeConversionService.fixedRates([:]), instrumentRegistry: registry)

    // Groups come back ordered by position, with all fields intact.
    let groups = try await cloudBackend.accountGroups.fetchAll()
    #expect(groups.map(\.id) == [seed.savings.id, seed.bills.id])
    #expect(groups.map(\.name) == ["Savings", "Bills"])
    #expect(groups.map(\.position) == [0, 1])
    #expect(groups.allSatisfy { $0.bucket == .current })
    #expect(groups.allSatisfy { $0.instrument == instrument })

    // The account keeps its membership in the second group.
    let accounts = try await cloudBackend.accounts.fetchAll()
    #expect(accounts.first?.groupId == seed.bills.id)
  }

  /// A pre-existing export file predates the `accountGroups` key. Decoding
  /// must tolerate its absence (defaulting to an empty list) rather than
  /// failing the whole import.
  @Test("legacy export without accountGroups key decodes to an empty list")
  func legacyExportDecodesWithoutGroups() throws {
    // UUID-keyed dictionaries (`earmarkBudgets`, `investmentValues`) are
    // encoded by Foundation as flat arrays, not JSON objects — empty ones
    // serialise as `[]`. The point of this fixture is the *absent*
    // `accountGroups` key, which the custom decoder must tolerate.
    let legacyJSON = """
      {
        "version": 1,
        "exportedAt": "2026-01-01T00:00:00Z",
        "profileLabel": "Legacy",
        "currencyCode": "\(instrument.id)",
        "financialYearStartMonth": 1,
        "instruments": [],
        "accounts": [],
        "categories": [],
        "earmarks": [],
        "earmarkBudgets": [],
        "transactions": [],
        "investmentValues": []
      }
      """
    let data = Data(legacyJSON.utf8)
    let decoded = try JSONDecoder.exportDecoder.decode(ExportedData.self, from: data)
    #expect(decoded.accountGroups.isEmpty)
  }
}
