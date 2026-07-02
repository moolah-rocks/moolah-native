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
  /// `balanceCalculator`, passing the cached externally-set investment value
  /// when the account is an investment account.
  func displayBalance(for accountId: UUID) async throws -> InstrumentAmount {
    guard let account = accounts.by(id: accountId) else {
      return .zero(instrument: targetInstrument)
    }
    return try await balanceCalculator.displayBalance(
      for: account, investmentValue: investmentValueCache.value(for: accountId))
  }

  /// Whether the sidebar should show "Not set" instead of `$0` for an
  /// investment account in `.recordedValue` mode (no snapshot recorded;
  /// initial conversion already completed). See
  /// `INSTRUMENT_CONVERSION_GUIDE.md` Rule 11 — `$0` would otherwise roll
  /// into net-worth as a real number.
  func hasUnrecordedValue(_ account: Account) -> Bool {
    guard hasCompletedInitialConversion else { return false }
    guard account.type == .investment, account.valuationMode == .recordedValue else {
      return false
    }
    return investmentValueCache.value(for: account.id) == nil
  }

  /// Whether an account can be deleted (all positions are zero or empty).
  func canDelete(_ accountId: UUID) -> Bool {
    guard let account = accounts.by(id: accountId) else { return false }
    return account.positions.isEmpty || account.positions.allSatisfy { $0.quantity == 0 }
  }

  /// Positions for a given account. Returns empty array if not loaded.
  func positions(for accountId: UUID) -> [Position] {
    accounts.by(id: accountId)?.positions ?? []
  }
}
