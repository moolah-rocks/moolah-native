import Foundation

/// Work and memory bounds are separate from the transport's encoded-response bound.
/// At most 250,000 Int64 quantities require at most 25 significant digits, within
/// Decimal's 38-digit capacity even before dividing by the fixed storage scale.
struct ReadAggregationBudget {
  static let maximumLegs = 250_000
  static let maximumKeys = 10_000
  let operation: ReadLimitOperation
  private var legs = 0

  /// Every operation starts with an unconsumed budget; callers cannot seed the counter.
  init(operation: ReadLimitOperation) {
    self.operation = operation
  }

  mutating func consume() throws {
    legs += 1
    if legs == 1 || legs.isMultiple(of: 1024) { try Task.checkCancellation() }
    guard legs <= Self.maximumLegs else {
      throw ReadLimitError(operation: operation, unit: .transactionLegs, maximum: Self.maximumLegs)
    }
  }

  func validateGroupCount(_ count: Int) throws {
    guard count <= Self.maximumKeys else {
      throw ReadLimitError(
        operation: operation,
        unit: .calculationGroups,
        maximum: Self.maximumKeys
      )
    }
  }

  static func adding(_ quantity: Int64, to previous: Decimal) throws -> Decimal {
    var left = previous
    var right = Decimal(quantity) / 100_000_000
    var result = Decimal()
    guard NSDecimalAdd(&result, &left, &right, .plain) == .noError, !result.isNaN else {
      throw ReadCalculationError.invalidResult
    }
    return result
  }
}
