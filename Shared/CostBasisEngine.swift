import Foundation

/// Pure synchronous engine for FIFO cost basis tracking.
///
/// Feed buy, sell, and move events in chronological order. The engine maintains open
/// lots per `(instrument, holding account)` and produces CapitalGainEvent values on sells.
///
/// Not async, no repository dependencies — all data passed in. Highly testable.
struct CostBasisEngine: Sendable {
  /// Identifies a bucket of open lots: one instrument held in one account.
  /// `account == nil` is the legacy single-bucket used by callers that do not
  /// yet segregate lots by account.
  private struct BucketKey: Hashable {
    let instrumentId: String
    let account: UUID?
  }

  /// Open lots grouped by `(instrument, account)`, in acquisition order (FIFO).
  private var buckets: [BucketKey: [CostBasisLot]] = [:]

  /// Record a buy: adds a new lot for the instrument in the given account's bucket.
  mutating func processBuy(
    instrument: Instrument,
    quantity: Decimal,
    costPerUnit: Decimal,
    date: Date,
    account: UUID? = nil
  ) {
    let lot = CostBasisLot(
      id: UUID(),
      instrument: instrument,
      acquiredDate: date,
      costPerUnit: costPerUnit,
      originalQuantity: quantity,
      remainingQuantity: quantity,
      account: account
    )
    buckets[BucketKey(instrumentId: instrument.id, account: account), default: []].append(lot)
  }

  /// Record a sell: consume lots in FIFO order within the account's bucket, return
  /// gain/loss events.
  ///
  /// If sell quantity exceeds available lots, only the available quantity is processed.
  mutating func processSell(
    instrument: Instrument,
    quantity: Decimal,
    proceedsPerUnit: Decimal,
    date: Date,
    account: UUID? = nil
  ) -> [CapitalGainEvent] {
    let key = BucketKey(instrumentId: instrument.id, account: account)
    var remaining = quantity
    var events: [CapitalGainEvent] = []
    let calendar = Calendar(identifier: .gregorian)

    while remaining > 0 {
      guard var lots = buckets[key], !lots.isEmpty else { break }

      var lot = lots[0]
      let consumed = min(remaining, lot.remainingQuantity)

      let holdingDays =
        calendar.dateComponents(
          [.day], from: lot.acquiredDate, to: date
        ).day ?? 0

      events.append(
        CapitalGainEvent(
          instrument: instrument,
          sellDate: date,
          acquiredDate: lot.acquiredDate,
          quantity: consumed,
          costBasis: consumed * lot.costPerUnit,
          proceeds: consumed * proceedsPerUnit,
          holdingDays: holdingDays
        ))

      lot.remainingQuantity -= consumed
      remaining -= consumed

      if lot.remainingQuantity <= 0 {
        lots.removeFirst()
      } else {
        lots[0] = lot
      }
      buckets[key] = lots
    }

    return events
  }

  /// Move lots of an instrument between holding accounts, consuming the source bucket
  /// FIFO and re-appending to the destination bucket with fresh ids but the original
  /// `costPerUnit` and `acquiredDate` preserved (the holding-period clock is not reset).
  /// Emits no gain — a move is not a disposal.
  ///
  /// If move quantity exceeds available lots, only the available quantity is moved.
  mutating func moveLots(
    instrument: Instrument,
    quantity: Decimal,
    from source: UUID?,
    to destination: UUID?
  ) {
    // A same-bucket move has no economic effect, and the shared-mutation loop below
    // would otherwise clobber the appended lots when re-writing the source bucket.
    guard source != destination else { return }
    let sourceKey = BucketKey(instrumentId: instrument.id, account: source)
    let destKey = BucketKey(instrumentId: instrument.id, account: destination)
    var remaining = quantity

    while remaining > 0 {
      guard var lots = buckets[sourceKey], !lots.isEmpty else { break }

      var lot = lots[0]
      let moved = min(remaining, lot.remainingQuantity)

      buckets[destKey, default: []].append(
        CostBasisLot(
          id: UUID(),
          instrument: instrument,
          acquiredDate: lot.acquiredDate,
          costPerUnit: lot.costPerUnit,
          originalQuantity: moved,
          remainingQuantity: moved,
          account: destination
        ))

      lot.remainingQuantity -= moved
      remaining -= moved

      if lot.remainingQuantity <= 0 {
        lots.removeFirst()
      } else {
        lots[0] = lot
      }
      buckets[sourceKey] = lots
    }
  }

  /// Return open (unsold) lots for an instrument in a specific account's bucket, FIFO order.
  func openLots(for instrument: Instrument, account: UUID?) -> [CostBasisLot] {
    buckets[BucketKey(instrumentId: instrument.id, account: account)] ?? []
  }

  /// Return open (unsold) lots for an instrument aggregated across all accounts.
  func allOpenLots(for instrument: Instrument) -> [CostBasisLot] {
    buckets.filter { $0.key.instrumentId == instrument.id }.flatMap(\.value)
  }

  /// All open lots across all instruments and accounts.
  func allOpenLots() -> [CostBasisLot] {
    buckets.values.flatMap { $0 }
  }
}
