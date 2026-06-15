import Foundation

extension EarmarkStore {
  // The members below are module-internal (not `private`) only because
  // `EarmarkStore.swift` and the SwiftUI views need them across file
  // boundaries. Treat them as the store's read-only query surface.

  func convertedBalance(for earmarkId: UUID) -> InstrumentAmount? {
    convertedBalances[earmarkId]
  }

  func convertedSaved(for earmarkId: UUID) -> InstrumentAmount? {
    convertedSavedAmounts[earmarkId]
  }

  func convertedSpent(for earmarkId: UUID) -> InstrumentAmount? {
    convertedSpentAmounts[earmarkId]
  }

  /// The balance for an earmark, converted to the earmark's own instrument.
  /// Recomputes from the earmark's positions on demand rather than reading
  /// the eventually-consistent `convertedBalances` dictionary, so callers
  /// (e.g. the "Get Earmark Balance" App Intent) get a correct value
  /// without waiting for the next conversion pass to settle. Throws on a
  /// real conversion failure rather than reporting a misleading zero.
  /// Returns zero in the reporting instrument when the earmark is unknown.
  func displayBalance(for earmarkId: UUID) async throws -> InstrumentAmount {
    guard let earmark = earmarks.by(id: earmarkId) else {
      return .zero(instrument: targetInstrument)
    }
    return try await convertEarmarkPositions(earmark).balance
  }
}
