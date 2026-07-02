import Foundation

// MARK: - Custom Mode Operations

extension TransactionDraft {
  /// Append a blank leg for custom mode editing. Callers should pass the default
  /// account's instrument so the leg is self-describing from the start.
  mutating func addLeg(defaultAccountId: UUID? = nil, instrument: Instrument? = nil) {
    legDrafts.append(
      LegDraft(
        legId: nil,
        type: .expense,
        accountId: defaultAccountId,
        amountText: "0",
        categoryId: nil,
        categoryText: "",
        earmarkId: nil,
        instrument: instrument
      ))
  }

  /// Remove a leg at the given index.
  mutating func removeLeg(at index: Int) {
    legDrafts.remove(at: index)
  }
}
