import Foundation
import Observation

@MainActor
@Observable
final class AccountTaxOwnerAssignmentStore {
  static let loadErrorMessage =
    "Couldn't load tax owners. Reopen the account editor and try again."
  private let loadErrorMessage: String

  private(set) var owners: [TaxOwner] = []
  private(set) var errorMessage: String?
  var selectedOwnerIds: [UUID]

  init(
    selectedOwnerIds: [UUID],
    loadErrorMessage: String = AccountTaxOwnerAssignmentStore.loadErrorMessage
  ) {
    self.loadErrorMessage = loadErrorMessage
    self.selectedOwnerIds = selectedOwnerIds
  }

  func loadOwners(from repository: any TaxOwnerRepository) async {
    do {
      applyLoadedOwners(try await repository.fetchAll())
    } catch {
      surfaceLoadFailure()
    }
  }

  func observeOwners(from repository: any TaxOwnerRepository) async {
    for await owners in repository.observeAll() {
      guard !Task.isCancelled else { return }
      applyLoadedOwners(owners)
    }
  }

  func observeErrors(from repository: any TaxOwnerRepository) async {
    for await _ in repository.observeErrors() {
      guard !Task.isCancelled else { return }
      surfaceLoadFailure()
    }
  }

  private func applyLoadedOwners(_ owners: [TaxOwner]) {
    self.owners = owners
    selectedOwnerIds = TaxOwnerAssignmentState.prunedSelectedOwnerIds(
      selectedOwnerIds, validOwners: owners)
    errorMessage = nil
  }

  private func surfaceLoadFailure() {
    errorMessage = loadErrorMessage
  }
}
