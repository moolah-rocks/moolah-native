import Foundation

enum CostBasisTransferEventBuilder {
  struct Input {
    let instrument: Instrument
    let quantity: Decimal
    let sourceAccount: UUID
    let destinationAccount: UUID
    let sourceAllocations: [CostBasisEventBuilder.OwnerAllocation]
    let destinationAllocations: [CostBasisEventBuilder.OwnerAllocation]
    let sourceTransactionId: UUID?
  }

  struct MarketValueInput {
    let transfer: Input
    let marketValue: Decimal
  }

  struct MarketValueFailure: Error {
    let fallbackEvents: [CostBasisEvent]
    let sourceDisposalHoldings: [CostBasisEventHolding]
    let destinationAcquisitionHoldings: [CostBasisEventHolding]
    let underlyingError: Error
  }

  static func sharedMoveEvents(input: Input) -> [CostBasisEvent] {
    var events: [CostBasisEvent] = []
    for allocation in input.sourceAllocations {
      let sharedFraction = min(
        allocation.fraction,
        ownerFraction(allocation.taxOwnerId, in: input.destinationAllocations))
      guard sharedFraction > 0 else { continue }
      events.append(
        .move(
          instrument: input.instrument,
          quantity: input.quantity * sharedFraction,
          route: CostBasisMoveRoute(
            from: input.sourceAccount,
            to: input.destinationAccount,
            taxOwnerId: allocation.taxOwnerId),
          marketValue: 0))
    }
    return events
  }

  static func marketValueEvents(input: MarketValueInput) -> [CostBasisEvent] {
    let marketValuePerUnit = input.marketValue / input.transfer.quantity
    var events: [CostBasisEvent] = []

    for sourceAllocation in input.transfer.sourceAllocations {
      let changingFraction = sourceChangingFraction(
        sourceAllocation, destinationAllocations: input.transfer.destinationAllocations)
      guard changingFraction > 0 else { continue }
      events.append(
        .disposal(
          instrument: input.transfer.instrument,
          quantity: input.transfer.quantity * changingFraction,
          proceedsPerUnit: marketValuePerUnit,
          context: CostBasisDisposalContext(
            holding: CostBasisEventHolding(
              account: input.transfer.sourceAccount,
              taxOwnerId: sourceAllocation.taxOwnerId),
            sourceTransactionId: input.transfer.sourceTransactionId)))
    }

    for destinationAllocation in input.transfer.destinationAllocations {
      let changingFraction = destinationChangingFraction(
        destinationAllocation, sourceAllocations: input.transfer.sourceAllocations)
      guard changingFraction > 0 else { continue }
      events.append(
        .acquisition(
          instrument: input.transfer.instrument,
          quantity: input.transfer.quantity * changingFraction,
          costPerUnit: marketValuePerUnit,
          holding: CostBasisEventHolding(
            account: input.transfer.destinationAccount,
            taxOwnerId: destinationAllocation.taxOwnerId)))
    }

    return events
  }

  static func sourceDisposalHoldings(input: Input) -> [CostBasisEventHolding] {
    input.sourceAllocations.compactMap { allocation in
      guard
        sourceChangingFraction(allocation, destinationAllocations: input.destinationAllocations) > 0
      else { return nil }
      return CostBasisEventHolding(account: input.sourceAccount, taxOwnerId: allocation.taxOwnerId)
    }
  }

  static func destinationAcquisitionHoldings(input: Input) -> [CostBasisEventHolding] {
    input.destinationAllocations.compactMap { allocation in
      guard destinationChangingFraction(allocation, sourceAllocations: input.sourceAllocations) > 0
      else { return nil }
      return CostBasisEventHolding(
        account: input.destinationAccount, taxOwnerId: allocation.taxOwnerId)
    }
  }

  private static func sourceChangingFraction(
    _ allocation: CostBasisEventBuilder.OwnerAllocation,
    destinationAllocations: [CostBasisEventBuilder.OwnerAllocation]
  ) -> Decimal {
    allocation.fraction
      - min(
        allocation.fraction,
        ownerFraction(allocation.taxOwnerId, in: destinationAllocations))
  }

  private static func destinationChangingFraction(
    _ allocation: CostBasisEventBuilder.OwnerAllocation,
    sourceAllocations: [CostBasisEventBuilder.OwnerAllocation]
  ) -> Decimal {
    allocation.fraction
      - min(
        allocation.fraction,
        ownerFraction(allocation.taxOwnerId, in: sourceAllocations))
  }

  private static func ownerFraction(
    _ taxOwnerId: UUID?,
    in allocations: [CostBasisEventBuilder.OwnerAllocation]
  ) -> Decimal {
    allocations.first { $0.taxOwnerId == taxOwnerId }?.fraction ?? 0
  }
}
