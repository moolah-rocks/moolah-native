import Foundation

/// Pure synchronous engine for FIFO cost basis tracking.
///
/// Feed buy, sell, and move events in chronological order. The engine maintains open
/// lots per `(instrument, holding account)` and produces CapitalGainEvent values on sells.
///
/// Not async, no repository dependencies — all data passed in. Highly testable.
struct CostBasisEngine: Sendable {
  /// Identifies a bucket of open lots: one instrument held for one tax owner,
  /// or (for legacy unowned callers) in one account. `nil` owner/account
  /// components preserve legacy single-bucket callers that do not resolve ownership.
  private struct BucketKey: Hashable {
    let instrumentId: String
    let account: UUID?
    let taxOwnerId: UUID?
  }

  /// Open lots grouped by `(instrument, tax owner)` or legacy `(instrument, account)`.
  private var buckets: [BucketKey: [CostBasisLot]] = [:]

  /// Record a buy: adds a new lot for the instrument in the given account/owner bucket.
  mutating func processBuy(
    instrument: Instrument,
    quantity: Decimal,
    costPerUnit: Decimal,
    date: Date,
    account: UUID? = nil,
    taxOwnerId: UUID? = nil
  ) {
    let lot = CostBasisLot(
      id: UUID(),
      instrument: instrument,
      acquiredDate: date,
      costPerUnit: costPerUnit,
      originalQuantity: quantity,
      remainingQuantity: quantity,
      account: account,
      taxOwnerId: taxOwnerId
    )
    buckets[
      bucketKey(instrument: instrument, account: account, taxOwnerId: taxOwnerId),
      default: []
    ].append(lot)
  }

  /// Record a sell: consume lots in FIFO order within the account/owner bucket,
  /// return gain/loss events.
  ///
  /// If sell quantity exceeds available lots, only the available quantity is processed.
  mutating func processSell(
    instrument: Instrument,
    quantity: Decimal,
    proceedsPerUnit: Decimal,
    date: Date,
    account: UUID? = nil,
    taxOwnerId: UUID? = nil,
    sourceTransactionId: UUID? = nil
  ) -> [CapitalGainEvent] {
    let key = bucketKey(instrument: instrument, account: account, taxOwnerId: taxOwnerId)
    var remaining = quantity
    var events: [CapitalGainEvent] = []
    while remaining > 0 {
      guard var lots = buckets[key], !lots.isEmpty else { break }

      var lot = lots[0]
      let consumed = min(remaining, lot.remainingQuantity)

      let holdingDays =
        Calendar.utc.dateComponents(
          [.day], from: lot.acquiredDate, to: date
        ).day ?? 0

      events.append(
        CapitalGainEvent(
          sourceTransactionId: sourceTransactionId,
          instrument: instrument,
          sellDate: date,
          acquiredDate: lot.acquiredDate,
          quantity: consumed,
          costBasis: consumed * lot.costPerUnit,
          proceeds: consumed * proceedsPerUnit,
          holdingDays: holdingDays,
          taxOwnerId: taxOwnerId
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
    to destination: UUID?,
    taxOwnerId: UUID? = nil
  ) {
    let sourceKey = bucketKey(instrument: instrument, account: source, taxOwnerId: taxOwnerId)
    let destKey = bucketKey(instrument: instrument, account: destination, taxOwnerId: taxOwnerId)
    if sourceKey == destKey {
      moveLotsWithinSharedBucket(
        key: sourceKey,
        quantity: quantity,
        from: source,
        to: destination,
        taxOwnerId: taxOwnerId)
      return
    }
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
          account: destination,
          taxOwnerId: taxOwnerId
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

  private mutating func moveLotsWithinSharedBucket(
    key: BucketKey,
    quantity: Decimal,
    from source: UUID?,
    to destination: UUID?,
    taxOwnerId: UUID?
  ) {
    guard source != destination, var lots = buckets[key], !lots.isEmpty else { return }
    var remaining = quantity
    var index = 0
    while remaining > 0 && index < lots.count {
      let lot = lots[index]
      guard lot.account == source else {
        index += 1
        continue
      }
      let moved = min(remaining, lot.remainingQuantity)
      let movedLot = CostBasisLot(
        id: UUID(),
        instrument: lot.instrument,
        acquiredDate: lot.acquiredDate,
        costPerUnit: lot.costPerUnit,
        originalQuantity: moved,
        remainingQuantity: moved,
        account: destination,
        taxOwnerId: taxOwnerId)
      if moved == lot.remainingQuantity {
        lots[index] = movedLot
      } else {
        var sourceLot = lot
        sourceLot.remainingQuantity -= moved
        lots[index] = sourceLot
        lots.insert(movedLot, at: index + 1)
        index += 1
      }
      remaining -= moved
      index += 1
    }
    buckets[key] = lots
  }

  /// Return open lots for an instrument in a specific account/owner bucket, FIFO order.
  func openLots(
    for instrument: Instrument,
    account: UUID?,
    taxOwnerId: UUID?
  ) -> [CostBasisLot] {
    let lots =
      buckets[
        bucketKey(instrument: instrument, account: account, taxOwnerId: taxOwnerId)
      ] ?? []
    guard taxOwnerId != nil else { return lots }
    return lots.filter { $0.account == account }
  }

  /// Return open lots for an instrument in a specific account, aggregated across owners.
  func openLots(for instrument: Instrument, account: UUID?) -> [CostBasisLot] {
    buckets
      .filter { $0.key.instrumentId == instrument.id && $0.key.account == account }
      .flatMap(\.value)
  }

  private func bucketKey(
    instrument: Instrument,
    account: UUID?,
    taxOwnerId: UUID?
  ) -> BucketKey {
    BucketKey(
      instrumentId: instrument.id,
      account: taxOwnerId == nil ? account : nil,
      taxOwnerId: taxOwnerId)
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
