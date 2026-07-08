import Foundation
import Observation

@MainActor
enum TaxOwnerStoreError: Error, Equatable {
  case cannotDeleteLastOwner
  case defaultDeleteNeedsReplacement
  case defaultOwnerRollbackFailed
  case invalidReplacementOwner
  case ownerNotFound
  case emptyName
}

@MainActor
@Observable
final class TaxOwnerStore {
  private let repository: any TaxOwnerRepository
  private let updateProfile: (Profile) async throws -> Void
  private var observationTask: Task<Void, Never>?
  private var observationErrorTask: Task<Void, Never>?
  private var isUpdatingDefaultOwner = false
  private var defaultOwnerUpdateWaiters: [CheckedContinuation<Void, Never>] = []

  private(set) var profile: Profile
  private(set) var owners: [TaxOwner] = []
  private(set) var errorMessage: String?

  var defaultOwner: TaxOwner? {
    owners.first { $0.id == profile.defaultTaxOwnerId }
  }

  var showsOwnerControls: Bool {
    owners.count > 1
  }

  init(
    profile: Profile,
    repository: any TaxOwnerRepository,
    updateProfile: @escaping (Profile) async throws -> Void
  ) {
    self.profile = profile
    self.repository = repository
    self.updateProfile = updateProfile
    observeOwners()
  }

  deinit {
    MainActor.assumeIsolated {
      observationTask?.cancel()
      observationErrorTask?.cancel()
    }
  }

  func loadOwners() async throws {
    owners = try await repository.fetchAll()
  }

  @discardableResult
  func addOwner(named name: String, kind: TaxOwnerKind) async throws -> TaxOwner {
    let owner = TaxOwner(name: try validatedName(name), kind: kind)
    let saved = try await repository.create(owner)
    owners = sortedReplacing(saved, in: owners)
    return saved
  }

  func renameOwner(id: UUID, to name: String) async throws {
    guard let owner = owners.first(where: { $0.id == id }) else {
      throw TaxOwnerStoreError.ownerNotFound
    }
    let renamed = TaxOwner(id: owner.id, name: try validatedName(name), kind: owner.kind)
    let saved = try await repository.update(renamed)
    owners = sortedReplacing(saved, in: owners)
  }

  func setDefaultOwner(id: UUID) async throws {
    guard owners.contains(where: { $0.id == id }) else {
      throw TaxOwnerStoreError.ownerNotFound
    }
    try await updateDefaultOwner(id)
  }

  func deleteOwner(id: UUID, replacementDefaultOwnerId: UUID? = nil) async throws {
    guard let owner = owners.first(where: { $0.id == id }) else {
      throw TaxOwnerStoreError.ownerNotFound
    }
    guard owners.count > 1 else {
      throw TaxOwnerStoreError.cannotDeleteLastOwner
    }

    let deletingDefaultOwner = owner.id == profile.defaultTaxOwnerId
    if deletingDefaultOwner {
      guard let replacementDefaultOwnerId else {
        throw TaxOwnerStoreError.defaultDeleteNeedsReplacement
      }
      guard owners.contains(where: { $0.id == replacementDefaultOwnerId && $0.id != id }) else {
        throw TaxOwnerStoreError.invalidReplacementOwner
      }
      try await updateDefaultOwner(replacementDefaultOwnerId)

      let ownerStillExists = owners.contains { $0.id == id }
      let replacementStillExists = owners.contains {
        $0.id == replacementDefaultOwnerId && $0.id != id
      }
      guard replacementStillExists else {
        if ownerStillExists {
          try await restoreDefaultOwnerAfterFailedDelete(owner)
        }
        throw TaxOwnerStoreError.invalidReplacementOwner
      }
      guard ownerStillExists else { return }
    }

    do {
      try await repository.delete(id: id)
      owners.removeAll { $0.id == id }
    } catch {
      if deletingDefaultOwner {
        try await restoreDefaultOwnerAfterFailedDelete(owner)
      }
      throw error
    }
  }

  func replacementOwners(for owner: TaxOwner) -> [TaxOwner] {
    owners.filter { $0.id != owner.id }
  }

  func clearError() {
    errorMessage = nil
  }

  func present(_ error: Error) {
    errorMessage = Self.message(for: error)
  }

  private func observeOwners() {
    let ownerStream = repository.observeAll()
    let errorStream = repository.observeErrors()

    observationTask = Task { @MainActor [weak self] in
      for await owners in ownerStream {
        self?.owners = owners
      }
    }
    observationErrorTask = Task { @MainActor [weak self] in
      for await error in errorStream {
        self?.present(error)
      }
    }
  }

  private func updateDefaultOwner(_ id: UUID) async throws {
    await waitForDefaultOwnerUpdateTurn()
    defer { finishDefaultOwnerUpdateTurn() }

    let previous = profile
    var updated = profile
    updated.defaultTaxOwnerId = id
    profile = updated
    do {
      try await updateProfile(updated)
    } catch {
      profile = previous
      throw error
    }
  }

  private func waitForDefaultOwnerUpdateTurn() async {
    guard isUpdatingDefaultOwner else {
      isUpdatingDefaultOwner = true
      return
    }

    await withCheckedContinuation { continuation in
      defaultOwnerUpdateWaiters.append(continuation)
    }
  }

  private func finishDefaultOwnerUpdateTurn() {
    guard !defaultOwnerUpdateWaiters.isEmpty else {
      isUpdatingDefaultOwner = false
      return
    }
    defaultOwnerUpdateWaiters.removeFirst().resume()
  }

  private func restoreDefaultOwnerAfterFailedDelete(_ owner: TaxOwner) async throws {
    do {
      try await updateDefaultOwner(owner.id)
    } catch {
      var restored = profile
      restored.defaultTaxOwnerId = owner.id
      profile = restored
      throw TaxOwnerStoreError.defaultOwnerRollbackFailed
    }
  }

  private func validatedName(_ name: String) throws -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw TaxOwnerStoreError.emptyName }
    return trimmed
  }

  private func sortedReplacing(_ owner: TaxOwner, in owners: [TaxOwner]) -> [TaxOwner] {
    var updated = owners.filter { $0.id != owner.id }
    updated.append(owner)
    return updated.sorted { lhs, rhs in
      let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
      if nameOrder != .orderedSame {
        return nameOrder == .orderedAscending
      }
      return lhs.id.uuidString < rhs.id.uuidString
    }
  }

  static func message(for error: Error) -> String {
    switch error {
    case TaxOwnerStoreError.cannotDeleteLastOwner:
      "Add another tax owner before deleting the last one."
    case TaxOwnerStoreError.defaultDeleteNeedsReplacement:
      "Choose a replacement default tax owner before deleting the current default."
    case TaxOwnerStoreError.defaultOwnerRollbackFailed:
      "The tax owner was not deleted, but restoring the default owner failed. Reopen Settings and try again."
    case TaxOwnerStoreError.invalidReplacementOwner:
      "Choose a different tax owner as the replacement default."
    case TaxOwnerStoreError.ownerNotFound:
      "That tax owner no longer exists."
    case TaxOwnerStoreError.emptyName:
      "Enter a tax owner name."
    default:
      "Couldn't update tax owners. Try again. If this keeps happening, reopen the profile."
    }
  }
}
