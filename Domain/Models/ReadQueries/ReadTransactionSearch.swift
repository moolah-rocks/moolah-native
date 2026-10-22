import Foundation

/// Only the filters supported by the read-only catalogue; every bound is enforced before SQL.
struct ReadTransactionSearch: Sendable {
  let range: ReadDateRange
  let accountIDs: Set<UUID>
  let categoryIDs: Set<UUID>
  let payeeQuery: String?
  let scheduled: Bool

  init(
    range: ReadDateRange,
    accountIDs: Set<UUID> = [],
    categoryIDs: Set<UUID> = [],
    payeeQuery: String? = nil,
    scheduled: Bool = false
  ) throws {
    try range.validate(horizon: .transactions)
    guard accountIDs.count <= 500, categoryIDs.count <= 500,
      (payeeQuery?.utf8.count ?? 0) <= 256
    else { throw ReadQueryError.invalidFilter }
    self.range = range
    self.accountIDs = accountIDs
    self.categoryIDs = categoryIDs
    self.payeeQuery = payeeQuery
    self.scheduled = scheduled
  }

  var transactionFilter: TransactionFilter {
    TransactionFilter(
      accountIds: accountIDs,
      scheduled: scheduled ? .scheduledOnly : .nonScheduledOnly,
      dateInterval: range.interval,
      categoryIds: categoryIDs,
      payee: payeeQuery
    )
  }
}
