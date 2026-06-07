import Foundation

// Investment-value operations for `AutomationService`. Lets a script clear an
// account's recorded value-history snapshots in bulk — e.g. a migration that
// retires a manual investment account and must not leave its value history
// behind to double-count against replacement accounts in the investment-value
// graph. The member is `@MainActor` via the containing class.
extension AutomationService {

  /// Clears every recorded investment value for the named account.
  ///
  /// Resolves the account by name (case-insensitive) from the authoritative
  /// repository snapshot, then deletes all of its `investment_value` rows via
  /// `InvestmentRepository.removeAllValues(accountId:)` — each deletion is
  /// enqueued for CloudKit sync. Throws `.accountNotFound` when the name does
  /// not resolve; other failures surface as `.operationFailed`.
  /// - Returns: The number of value rows deleted.
  func clearInvestmentValues(
    profileIdentifier: String,
    accountName: String
  ) async throws -> Int {
    let session = try resolveSession(for: profileIdentifier)
    let account = try await resolveAccount(
      named: accountName, profileIdentifier: profileIdentifier)
    do {
      return try await session.backend.investments.removeAllValues(accountId: account.id)
    } catch {
      throw AutomationError.operationFailed(
        "Failed to clear investment values: \(error.localizedDescription)")
    }
  }
}
