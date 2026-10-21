import Foundation

struct ReadTransactionDTO: Codable, Sendable, Equatable {
  let id: UUID
  let date: Date
  let payee: String?
  let notes: String?
  let scheduled: Bool
  let legs: [ReadTransactionLegDTO]

  init(_ transaction: Transaction, includeNotes: Bool, filter: TransactionFilter) {
    id = transaction.id
    date = transaction.date
    payee = transaction.payee
    notes = includeNotes ? transaction.notes : nil
    scheduled = transaction.isScheduled
    legs = transaction.legs.map { leg in
      ReadTransactionLegDTO(leg, filter: filter)
    }
  }
}

struct ReadTransactionLegDTO: Codable, Sendable, Equatable {
  let id: UUID
  let accountID: UUID?
  let amount: ReadQuantityDTO
  let type: String
  let categoryID: UUID?
  let earmarkID: UUID?
  let matchesFilters: Bool

  init(_ leg: TransactionLeg, filter: TransactionFilter) {
    id = leg.id
    accountID = leg.accountId
    amount = ReadQuantityDTO(quantity: leg.quantity, instrument: leg.instrument)
    type = leg.type.rawValue
    categoryID = leg.categoryId
    earmarkID = leg.earmarkId
    var accountIDs = filter.accountIds
    if let id = filter.accountId { accountIDs.insert(id) }
    let matchesAccount = accountIDs.isEmpty || leg.accountId.map(accountIDs.contains) == true
    let matchesCategory =
      filter.categoryIds.isEmpty || leg.categoryId.map(filter.categoryIds.contains) == true
    matchesFilters = matchesAccount && matchesCategory
  }
}
