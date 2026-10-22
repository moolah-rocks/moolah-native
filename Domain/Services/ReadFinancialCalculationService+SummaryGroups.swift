import Foundation

extension ReadFinancialCalculationService {
  func summaryGroups(_ input: ReadSummaryGroupContext) throws -> [ReadSummaryGroupDTO] {
    guard input.grouping != .none else { return [] }
    let categories = try summaryCategoryMap(input)
    let members = try summaryGroupMembers(input, categories: categories)
    var result: [ReadSummaryGroupDTO] = []
    var outputQuantities = 0
    for key in members.keys.sorted() {
      try Task.checkCancellation()
      let sources = members[key] ?? []
      let indexed = zip(input.buckets, input.values).filter {
        $0.0.month == key.month && sources.contains($0.0.categoryID)
      }
      let income = wireTotals(indexed.filter { $0.0.type == .income }.map { $0.0.amount })
      let spending = wireTotals(indexed.filter { $0.0.type == .expense }.map { $0.0.amount })
      outputQuantities += income.count + spending.count
      guard outputQuantities <= 10_000 else {
        throw ReadLimitError(operation: .summaryGroups, unit: .calculationGroups, maximum: 10_000)
      }
      result.append(
        ReadSummaryGroupDTO(
          categoryID: key.categoryID,
          categoryName: key.categoryID.flatMap { categories[$0]?.name },
          parentCategoryID: key.categoryID.flatMap { categories[$0]?.parentID },
          month: key.month,
          includesDescendants: key.categoryID != nil && input.grouping.includesCategories
            && input.includeParentTotals,
          income: income,
          spending: spending,
          reportingIncome: total(
            indexed.filter { $0.0.type == .income }.map(\.1),
            target: input.target,
            on: nil
          ).dto,
          reportingSpending: total(
            indexed.filter { $0.0.type == .expense }.map(\.1),
            target: input.target,
            on: nil
          ).dto
        )
      )
    }
    return result
  }

  private func summaryCategoryMap(_ input: ReadSummaryGroupContext) throws -> [UUID:
    ReadCategoryDTO]
  {
    var categories: [UUID: ReadCategoryDTO] = [:]
    for category in input.categories {
      guard categories.updateValue(category, forKey: category.id) == nil else {
        throw ReadCalculationError.invalidResult
      }
    }
    for id in Set(input.buckets.compactMap(\.categoryID)) {
      guard categories[id] != nil else { throw ReadCalculationError.invalidResult }
    }
    return categories
  }

  private func summaryGroupMembers(
    _ input: ReadSummaryGroupContext,
    categories: [UUID: ReadCategoryDTO]
  ) throws -> [ReadSummaryGroupKey: Set<UUID?>] {
    var members: [ReadSummaryGroupKey: Set<UUID?>] = [:]
    var paths: [UUID: [UUID?]] = [:]
    for bucket in input.buckets {
      try Task.checkCancellation()
      let ids: [UUID?]
      if let id = bucket.categoryID, input.grouping.includesCategories, input.includeParentTotals {
        if let cached = paths[id] {
          ids = cached
        } else {
          ids = try summaryAncestors(id, categories: categories)
          paths[id] = ids
        }
      } else {
        ids = [bucket.categoryID]
      }
      for id in ids {
        members[ReadSummaryGroupKey(month: bucket.month, categoryID: id), default: []].insert(
          bucket.categoryID
        )
        guard members.count <= 500 else {
          throw ReadLimitError(operation: .summaryGroups, unit: .calculationGroups, maximum: 500)
        }
      }
    }
    return members
  }

  private func summaryAncestors(_ id: UUID, categories: [UUID: ReadCategoryDTO]) throws -> [UUID?] {
    var current: UUID? = id
    var seen: Set<UUID> = []
    var result: [UUID?] = []
    while let next = current {
      guard seen.insert(next).inserted, let category = categories[next] else {
        throw ReadCalculationError.invalidResult
      }
      result.append(next)
      guard result.count <= 500 else {
        throw ReadLimitError(operation: .summaryGroups, unit: .calculationGroups, maximum: 500)
      }
      current = category.parentID
    }
    return result
  }
}

/// Inputs are bounded daily buckets; category memberships avoid duplicating raw transaction history.
struct ReadSummaryGroupContext: Sendable {
  let buckets: [ReadSummaryBucket]
  let values: [ReadValuation]
  let categories: [ReadCategoryDTO]
  let target: Instrument
  let grouping: ReadSummaryGrouping
  let includeParentTotals: Bool
}

private struct ReadSummaryGroupKey {
  let month: String?
  let categoryID: UUID?
}

extension ReadSummaryGroupKey: Hashable {}
extension ReadSummaryGroupKey: Comparable {
  static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.month != rhs.month { return (lhs.month ?? "") < (rhs.month ?? "") }
    return (lhs.categoryID?.uuidString ?? "") < (rhs.categoryID?.uuidString ?? "")
  }
}
