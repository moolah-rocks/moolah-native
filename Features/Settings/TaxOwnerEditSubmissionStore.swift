import Foundation
import Observation

@Observable
@MainActor
final class TaxOwnerEditSubmissionStore {
  var isSubmitting = false
  var errorMessage: String?

  func submit(
    name: String,
    kind: TaxOwnerKind,
    save: @MainActor (String, TaxOwnerKind) async throws -> Void,
    dismiss: @MainActor () -> Void
  ) async {
    guard !isSubmitting else { return }
    isSubmitting = true
    errorMessage = nil

    do {
      try await save(name, kind)
      dismiss()
    } catch {
      errorMessage = TaxOwnerStore.message(for: error)
      isSubmitting = false
    }
  }
}
