#if os(macOS)
  import Foundation
  import Testing

  @testable import Moolah

  @Suite("AutomationService Profile Export/Import")
  @MainActor
  struct AutomationServiceExportImportTests {
    private func makeTempFileURL() -> URL {
      FileManager.default.temporaryDirectory
        .appendingPathComponent("moolah-automation-export-\(UUID().uuidString).json")
    }

    private struct Harness {
      let service: AutomationService
      let sessionManager: SessionManager
      let profileStore: ProfileStore
      let containerManager: ProfileContainerManager
    }

    private func makeHarness() throws -> Harness {
      let containerManager = try ProfileContainerManager.forTesting()
      let sessionManager = SessionManager(
        containerManager: containerManager,
        profileIndexRepository: containerManager.profileIndexRepositoryForTesting)
      let defaults = try #require(UserDefaults(suiteName: "test-\(UUID().uuidString)"))
      let profileStore = ProfileStore(
        defaults: defaults,
        containerManager: containerManager
      )
      let service = AutomationService(sessionManager: sessionManager)
      return Harness(
        service: service,
        sessionManager: sessionManager,
        profileStore: profileStore,
        containerManager: containerManager
      )
    }

    @Test("exportProfile writes JSON for an open profile")
    func exportWritesJSON() async throws {
      let harness = try makeHarness()
      let profile = Profile(
        label: "Test Profile",
        currencyCode: "AUD",
        financialYearStartMonth: 7
      )
      guard case .ready(let session) = await harness.sessionManager.session(for: profile)
      else {
        Issue.record("expected .ready")
        return
      }
      try await session.accountStore.waitForFirstEmission()

      _ = try await harness.service.createAccount(
        profileIdentifier: "Test Profile",
        name: "Checking",
        type: .bank
      )

      let tempURL = makeTempFileURL()
      defer { try? FileManager.default.removeItem(at: tempURL) }

      try await harness.service.exportProfile(
        profileIdentifier: "Test Profile", to: tempURL)

      #expect(FileManager.default.fileExists(atPath: tempURL.path))
      let data = try Data(contentsOf: tempURL)
      let decoded = try JSONDecoder.exportDecoder.decode(ExportedData.self, from: data)
      #expect(decoded.profileLabel == "Test Profile")
      #expect(decoded.currencyCode == "AUD")
      #expect(decoded.accounts.count == 1)
      #expect(decoded.accounts.first?.name == "Checking")
    }

    @Test("exportProfile throws when profile not found")
    func exportThrowsWhenProfileMissing() async throws {
      let harness = try makeHarness()
      let tempURL = makeTempFileURL()
      defer { try? FileManager.default.removeItem(at: tempURL) }

      await #expect(throws: AutomationError.self) {
        try await harness.service.exportProfile(
          profileIdentifier: "Nonexistent", to: tempURL)
      }
    }

    @Test("importProfile creates a new profile from an exported JSON file")
    func importCreatesProfile() async throws {
      let harness = try makeHarness()

      let sourceProfile = Profile(
        label: "Source Profile",
        currencyCode: "AUD",
        financialYearStartMonth: 7
      )
      guard
        case .ready(let sourceSession) = await harness.sessionManager.session(
          for: sourceProfile)
      else {
        Issue.record("expected .ready")
        return
      }
      try await sourceSession.accountStore.waitForFirstEmission()
      _ = try await harness.service.createAccount(
        profileIdentifier: "Source Profile",
        name: "Savings",
        type: .bank
      )

      let tempURL = makeTempFileURL()
      defer { try? FileManager.default.removeItem(at: tempURL) }
      try await harness.service.exportProfile(
        profileIdentifier: "Source Profile", to: tempURL)

      let imported = try await harness.service.importProfile(
        from: tempURL,
        profileStore: harness.profileStore,
        containerManager: harness.containerManager,
        syncCoordinator: nil
      )

      #expect(imported.label == "Source Profile")
      #expect(imported.currencyCode == "AUD")
      #expect(imported.id != sourceProfile.id)

      guard
        case .ready(let importedSession) = await harness.sessionManager.session(
          for: imported)
      else {
        Issue.record("expected .ready")
        return
      }
      // The imported account becomes observable on the reactive store shortly
      // after the import write commits. Poll the exact asserted value so a
      // racing observation pass can't slip a stale read between an awaited
      // emission and a single read.
      await expectEventually("imported account is observable on the store") {
        importedSession.accountStore.accounts.contains { $0.name == "Savings" }
      }
    }

    @Test("importProfile throws for a missing file")
    func importThrowsForMissingFile() async throws {
      let harness = try makeHarness()
      let fakeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("does-not-exist-\(UUID().uuidString).json")

      await #expect(throws: AutomationError.self) {
        _ = try await harness.service.importProfile(
          from: fakeURL,
          profileStore: harness.profileStore,
          containerManager: harness.containerManager,
          syncCoordinator: nil
        )
      }
    }

    @Test("importProfile throws when profile store is not configured")
    func importThrowsWithoutProfileStore() async throws {
      let containerManager = try ProfileContainerManager.forTesting()
      let sessionManager = SessionManager(
        containerManager: containerManager,
        profileIndexRepository: containerManager.profileIndexRepositoryForTesting)
      let service = AutomationService(sessionManager: sessionManager)

      let tempURL = makeTempFileURL()

      await #expect(throws: AutomationError.self) {
        _ = try await service.importProfile(
          from: tempURL,
          profileStore: nil,
          containerManager: containerManager,
          syncCoordinator: nil
        )
      }
    }
  }
#endif
