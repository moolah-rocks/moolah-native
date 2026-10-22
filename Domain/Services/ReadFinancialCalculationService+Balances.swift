import Foundation

extension ReadFinancialCalculationService {
  /// One batch spans every account; partitioning preserves each native position and dependent total.
  func balances(
    _ inputs: [ReadBalanceInput],
    target: Instrument,
    on date: Date,
    includePositions: Bool = true
  ) async throws -> (
    [ReadValuedBalanceDTO], [String]
  ) {
    let amounts = inputs.flatMap(\.positions)
    let values = try await value(
      amounts.map { ReadDatedAmount(amount: $0, date: date) },
      target: target
    )
    var offset = 0
    var items: [ReadValuedBalanceDTO] = []
    for input in inputs {
      try Task.checkCancellation()
      let end = offset + input.positions.count
      let accountValues = Array(values[offset..<end])
      let positions =
        includePositions
        ? zip(input.positions, accountValues).map { amount, value in
          ReadValuedPositionDTO(
            native: ReadQuantityDTO(quantity: amount.quantity, instrument: amount.instrument),
            valuation: value.dto
          )
        }
        : []
      items.append(
        ReadValuedBalanceDTO(
          accountID: input.accountID,
          positions: positions,
          total: total(accountValues, target: target, on: date).dto,
          accountName: input.accountName,
          positionsIncluded: includePositions
        )
      )
      offset = end
    }
    return (items, warnings(values, originalAmountsIncluded: includePositions))
  }
}
