import Foundation
import Observation

@MainActor
@Observable
final class CategoryTaxOwnerAssignmentStore {
  static let loadErrorMessage =
    "Couldn't load tax owners. Reopen the category editor and try again."

  private(set) var owners: [TaxOwner] = []
  private(set) var errorMessage: String?
  private(set) var selectedCategory: Category?

  func select(_ category: Category?) {
    selectedCategory = category.map { category in
      self.category(category, pruningTaxOwnersAgainst: owners)
    }
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
    errorMessage = nil
    selectedCategory = selectedCategory.map { category in
      self.category(category, pruningTaxOwnersAgainst: owners)
    }
  }

  private func surfaceLoadFailure() {
    errorMessage = Self.loadErrorMessage
  }

  private func category(_ category: Category, pruningTaxOwnersAgainst owners: [TaxOwner])
    -> Category
  {
    var pruned = category
    pruned.taxOwnerIds = TaxOwnerAssignmentState.prunedSelectedOwnerIds(
      category.taxOwnerIds, validOwners: owners)
    return pruned
  }
}
