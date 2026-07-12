import Foundation

extension ProfileSession {
  /// Runs the bootstrap migrations off `@MainActor` and reloads the
  /// affected stores. Idempotent: subsequent calls return the same
  /// task so callers can `await session.setUp()` from multiple sites
  /// (UI test seed setup, `SessionManager.session(for:)`, etc.) without
  /// re-running anything.
  ///
  func setUp() async throws {
    if let existing = setUpTask {
      return try await existing.value
    }
    let task = Task<Void, any Error> {
      try await self.bootstrapImplicitDefaultTaxOwner()
    }
    setUpTask = task
    try await task.value
  }

  private func bootstrapImplicitDefaultTaxOwner() async throws {
    guard let backend = backend as? CloudKitBackend else { return }
    try await Task.detached {
      try backend.grdbTaxOwners.bootstrapImplicitDefaultOwner()
    }.value
  }
}
