import Foundation

extension AccountStore {
  // The members below are module-internal (not `private`) only because
  // `AccountStore.swift` and the SwiftUI views need them across file
  // boundaries. Treat them as the store's read-only query surface.

  /// Current-bucket accounts, honouring `showHidden`.
  var currentAccounts: [Account] {
    accounts.filter { $0.bucket == .current && (showHidden || !$0.isHidden) }
  }

  /// Investment-bucket accounts, honouring `showHidden`.
  var investmentAccounts: [Account] {
    accounts.filter { $0.bucket == .investments && (showHidden || !$0.isHidden) }
  }

  /// The display balance for an account in its own instrument. Forwards to
  /// `balanceCalculator`.
  func displayBalance(for accountId: UUID) async throws -> InstrumentAmount {
    guard let account = accounts.by(id: accountId) else {
      return .zero(instrument: targetInstrument)
    }
    return try await balanceCalculator.displayBalance(for: account)
  }

  /// Whether an account can be deleted (all positions are zero or empty).
  func canDelete(_ accountId: UUID) -> Bool {
    guard let account = accounts.by(id: accountId) else { return false }
    return account.positions.isEmpty || account.positions.allSatisfy { $0.quantity == 0 }
  }

  /// Whether the "Hidden" flag may be changed for an account.
  ///
  /// Hiding a live account is disallowed (same zero-balance rule as
  /// ``canDelete(_:)``), but an already-hidden account may *always* be
  /// unhidden — even if it has since regained a balance — otherwise it
  /// would be stuck hidden with no way to bring it back into view.
  func canToggleHidden(_ accountId: UUID) -> Bool {
    guard let account = accounts.by(id: accountId) else { return false }
    return account.isHidden || canDelete(accountId)
  }

  /// Positions for a given account. Returns empty array if not loaded.
  func positions(for accountId: UUID) -> [Position] {
    accounts.by(id: accountId)?.positions ?? []
  }
}
