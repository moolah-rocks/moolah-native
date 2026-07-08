// MoolahTests/Features/Settings/TaxOwnerStoreTests.swift

import Foundation
import Testing

@testable import Moolah

@MainActor
@Suite("TaxOwnerStore")
struct TaxOwnerStoreTests {
  @Test("loadOwners exposes every owner with the profile default selected")
  func loadOwnersExposesProfileDefault() async throws {
    let fixture = try makeFixture()
    let defaultOwner = TaxOwner(id: fixture.profile.defaultTaxOwnerId, name: "Alex")
    let otherOwner = TaxOwner(id: ownerBId, name: "Jordan")
    try await fixture.seedOwners(defaultOwner, otherOwner)

    try await fixture.store.loadOwners()

    #expect(fixture.store.owners.map(\.id) == [defaultOwner.id, otherOwner.id])
    #expect(fixture.store.defaultOwner?.id == defaultOwner.id)
  }

  @Test("addOwner persists the new owner")
  func addOwnerPersistsNewOwner() async throws {
    let fixture = try makeFixture()
    try await fixture.seedOwners(TaxOwner(id: fixture.profile.defaultTaxOwnerId, name: "Alex"))
    try await fixture.store.loadOwners()

    let added = try await fixture.store.addOwner(named: "Family Trust", kind: TaxOwnerKind.trust)

    #expect(added.name == "Family Trust")
    #expect(added.kind == TaxOwnerKind.trust)
    let saved = try #require(
      try await fixture.backend.taxOwners.fetchAll().first { $0.id == added.id })
    #expect(saved == added)
    #expect(fixture.store.owners.contains(added))
  }

  @Test("renameOwner changes only that owner")
  func renameOwnerChangesOnlyThatOwner() async throws {
    let fixture = try makeFixture()
    let defaultOwner = TaxOwner(id: fixture.profile.defaultTaxOwnerId, name: "Alex")
    let trust = TaxOwner(id: ownerBId, name: "Family Trust", kind: TaxOwnerKind.trust)
    try await fixture.seedOwners(defaultOwner, trust)
    try await fixture.store.loadOwners()

    try await fixture.store.renameOwner(id: trust.id, to: "Smith Family Trust")

    let saved = try #require(
      try await fixture.backend.taxOwners.fetchAll().first { $0.id == trust.id })
    #expect(saved == TaxOwner(id: trust.id, name: "Smith Family Trust", kind: TaxOwnerKind.trust))
    #expect(fixture.store.owners.first { $0.id == defaultOwner.id } == defaultOwner)
  }

  @Test("setDefaultOwner updates the profile through the injected updater")
  func setDefaultOwnerUsesProfileUpdater() async throws {
    let fixture = try makeFixture()
    let defaultOwner = TaxOwner(id: fixture.profile.defaultTaxOwnerId, name: "Alex")
    let newDefault = TaxOwner(id: ownerBId, name: "Jordan")
    try await fixture.seedOwners(defaultOwner, newDefault)
    try await fixture.store.loadOwners()

    try await fixture.store.setDefaultOwner(id: newDefault.id)

    #expect(fixture.profileUpdates.profiles.map(\.defaultTaxOwnerId) == [newDefault.id])
    #expect(fixture.store.defaultOwner?.id == newDefault.id)
  }

  @Test("deleteOwner removes a non-default owner")
  func deleteOwnerRemovesNonDefaultOwner() async throws {
    let fixture = try makeFixture()
    let defaultOwner = TaxOwner(id: fixture.profile.defaultTaxOwnerId, name: "Alex")
    let otherOwner = TaxOwner(id: ownerBId, name: "Jordan")
    try await fixture.seedOwners(defaultOwner, otherOwner)
    try await fixture.store.loadOwners()

    try await fixture.store.deleteOwner(id: otherOwner.id)

    #expect(try await fixture.backend.taxOwners.fetchAll().map(\.id) == [defaultOwner.id])
    #expect(fixture.store.owners.map(\.id) == [defaultOwner.id])
  }

  @Test("deleteOwner refuses to remove the last owner")
  func deleteOwnerRefusesLastOwner() async throws {
    let fixture = try makeFixture()
    let defaultOwner = TaxOwner(id: fixture.profile.defaultTaxOwnerId, name: "Alex")
    try await fixture.seedOwners(defaultOwner)
    try await fixture.store.loadOwners()

    await expectCannotDeleteLastOwner {
      try await fixture.store.deleteOwner(id: defaultOwner.id)
    }

    #expect(try await fixture.backend.taxOwners.fetchAll().map(\.id) == [defaultOwner.id])
    #expect(fixture.profileUpdates.profiles.isEmpty)
  }

  @Test("deleteOwner refuses the default owner without a replacement")
  func deleteOwnerRefusesDefaultOwnerWithoutReplacement() async throws {
    let fixture = try makeFixture()
    let defaultOwner = TaxOwner(id: fixture.profile.defaultTaxOwnerId, name: "Alex")
    let replacement = TaxOwner(id: ownerBId, name: "Jordan")
    try await fixture.seedOwners(defaultOwner, replacement)
    try await fixture.store.loadOwners()

    await expectCannotDeleteDefaultOwnerWithoutReplacement {
      try await fixture.store.deleteOwner(id: defaultOwner.id)
    }

    #expect(
      try await fixture.backend.taxOwners.fetchAll().map(\.id) == [defaultOwner.id, replacement.id])
    #expect(fixture.profileUpdates.profiles.isEmpty)
  }

  @Test("deleteOwner replaces the default before removing it")
  func deleteOwnerReplacesDefaultBeforeRemovingIt() async throws {
    let fixture = try makeFixture()
    let defaultOwner = TaxOwner(id: fixture.profile.defaultTaxOwnerId, name: "Alex")
    let replacement = TaxOwner(id: ownerBId, name: "Jordan")
    try await fixture.seedOwners(defaultOwner, replacement)
    try await fixture.store.loadOwners()

    try await fixture.store.deleteOwner(
      id: defaultOwner.id, replacementDefaultOwnerId: replacement.id)

    #expect(fixture.profileUpdates.profiles.map(\.defaultTaxOwnerId) == [replacement.id])
    #expect(
      fixture.profileUpdates.ownerIdsVisibleDuringUpdate == [[defaultOwner.id, replacement.id]])
    #expect(try await fixture.backend.taxOwners.fetchAll().map(\.id) == [replacement.id])
    #expect(fixture.store.defaultOwner?.id == replacement.id)
  }

  @Test("deleteOwner keeps replacement default when the old default disappears during update")
  func deleteOwnerKeepsReplacementDefaultWhenOldDefaultDisappearsDuringUpdate() async throws {
    let fixture = try makeFixture()
    let defaultOwner = TaxOwner(id: fixture.profile.defaultTaxOwnerId, name: "Alex")
    let replacement = TaxOwner(id: ownerBId, name: "Jordan")
    try await fixture.seedOwners(defaultOwner, replacement)
    try await fixture.store.loadOwners()
    fixture.profileUpdates.afterUpdate = { _ in
      try await fixture.backend.taxOwners.delete(id: defaultOwner.id)
      try await fixture.store.loadOwners()
    }

    try await fixture.store.deleteOwner(
      id: defaultOwner.id,
      replacementDefaultOwnerId: replacement.id)

    #expect(fixture.profileUpdates.profiles.map(\.defaultTaxOwnerId) == [replacement.id])
    #expect(try await fixture.backend.taxOwners.fetchAll().map(\.id) == [replacement.id])
    #expect(fixture.store.defaultOwner?.id == replacement.id)
  }

  @Test("showsOwnerControls turns on only after a second owner exists")
  func showsOwnerControlsTracksOwnerCount() async throws {
    let fixture = try makeFixture()
    try await fixture.seedOwners(TaxOwner(id: fixture.profile.defaultTaxOwnerId, name: "Alex"))
    try await fixture.store.loadOwners()

    #expect(fixture.store.showsOwnerControls == false)

    _ = try await fixture.store.addOwner(named: "Jordan", kind: TaxOwnerKind.individual)

    #expect(fixture.store.showsOwnerControls == true)
  }

  // MARK: - Helpers

  private let ownerBId = makeUUID("00000000-0000-0000-0000-0000000000B2")
  private let defaultOwnerId = makeUUID("00000000-0000-0000-0000-0000000000D1")
  private let profileId = makeUUID("00000000-0000-0000-0000-000000000127")

  private func makeFixture() throws -> Fixture {
    let created = try TestBackend.create()
    let profile = Profile(
      id: profileId,
      label: "Family",
      defaultTaxOwnerId: defaultOwnerId,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    let profileUpdates = ProfileUpdateRecorder(repository: created.backend.taxOwners)
    let store = TaxOwnerStore(
      profile: profile,
      repository: created.backend.taxOwners,
      updateProfile: profileUpdates.update)
    return Fixture(
      profile: profile,
      backend: created.backend,
      store: store,
      profileUpdates: profileUpdates)
  }

  private func expectCannotDeleteLastOwner(
    _ operation: () async throws -> Void
  ) async {
    do {
      try await operation()
      Issue.record("deleteOwner should reject removing the final owner")
    } catch TaxOwnerStoreError.cannotDeleteLastOwner {
      // Expected.
    } catch {
      Issue.record("deleteOwner threw \(error) instead of cannotDeleteLastOwner")
    }
  }

  private func expectCannotDeleteDefaultOwnerWithoutReplacement(
    _ operation: () async throws -> Void
  ) async {
    do {
      try await operation()
      Issue.record("deleteOwner should reject removing the default owner without a replacement")
    } catch TaxOwnerStoreError.defaultDeleteNeedsReplacement {
      // Expected.
    } catch {
      Issue.record("deleteOwner threw \(error) instead of defaultDeleteNeedsReplacement")
    }
  }

  private struct Fixture {
    let profile: Profile
    let backend: CloudKitBackend
    let store: TaxOwnerStore
    let profileUpdates: ProfileUpdateRecorder

    func seedOwners(_ owners: TaxOwner...) async throws {
      for owner in owners {
        _ = try await backend.taxOwners.create(owner)
      }
    }
  }

  @MainActor
  private final class ProfileUpdateRecorder {
    private let repository: any TaxOwnerRepository
    private(set) var profiles: [Profile] = []
    private(set) var ownerIdsVisibleDuringUpdate: [[UUID]] = []
    var afterUpdate: ((Profile) async throws -> Void)?

    init(repository: any TaxOwnerRepository) {
      self.repository = repository
    }

    func update(_ profile: Profile) async throws {
      profiles.append(profile)
      ownerIdsVisibleDuringUpdate.append(try await repository.fetchAll().map(\.id))
      try await afterUpdate?(profile)
    }
  }
}
