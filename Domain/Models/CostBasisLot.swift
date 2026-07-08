import Foundation

/// A lot (tax parcel) of an instrument acquired at a specific cost on a specific date.
/// Used by the FIFO cost basis engine to track open positions.
struct CostBasisLot: Sendable, Hashable, Identifiable {
  let id: UUID
  let instrument: Instrument
  let acquiredDate: Date
  let costPerUnit: Decimal
  let originalQuantity: Decimal
  var remainingQuantity: Decimal
  /// Tax owner partition for this lot. `nil` for legacy callers that do not
  /// resolve tax ownership.
  let taxOwnerId: UUID?
  /// Holding-account tag. `nil` for legacy single-bucket callers that do not
  /// segregate lots by account.
  let account: UUID?

  init(
    id: UUID,
    instrument: Instrument,
    acquiredDate: Date,
    costPerUnit: Decimal,
    originalQuantity: Decimal,
    remainingQuantity: Decimal,
    account: UUID? = nil,
    taxOwnerId: UUID? = nil
  ) {
    self.id = id
    self.instrument = instrument
    self.acquiredDate = acquiredDate
    self.costPerUnit = costPerUnit
    self.originalQuantity = originalQuantity
    self.remainingQuantity = remainingQuantity
    self.account = account
    self.taxOwnerId = taxOwnerId
  }

  var totalCost: Decimal { originalQuantity * costPerUnit }
  var remainingCost: Decimal { remainingQuantity * costPerUnit }
}
