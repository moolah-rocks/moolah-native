import Foundation
import GRDB

extension GRDBTransactionRepository {
  static func applyingHeaderFilters(
    to request: QueryInterfaceRequest<TransactionRow>,
    filter: TransactionFilter
  ) -> QueryInterfaceRequest<TransactionRow> {
    var request = request
    request = applyingScheduledFilter(to: request, scheduled: filter.scheduled)
    request = applyingDateFilters(to: request, filter: filter)
    return applyingPayeeFilter(to: request, payee: filter.payee)
  }

  private static func applyingScheduledFilter(
    to request: QueryInterfaceRequest<TransactionRow>,
    scheduled: ScheduledFilter
  ) -> QueryInterfaceRequest<TransactionRow> {
    switch scheduled {
    case .all, .nonScheduledOnly:
      return request.filter(TransactionRow.Columns.recurPeriod == nil)
    case .scheduledOnly:
      return request.filter(TransactionRow.Columns.recurPeriod != nil)
    }
  }

  private static func applyingDateFilters(
    to request: QueryInterfaceRequest<TransactionRow>,
    filter: TransactionFilter
  ) -> QueryInterfaceRequest<TransactionRow> {
    var request = request
    if let dateInterval = filter.dateInterval {
      request = request.filter(
        TransactionRow.Columns.date >= dateInterval.lowerBound
          && TransactionRow.Columns.date < dateInterval.upperBound)
    }
    if let dateRange = filter.dateRange {
      request = request.filter(
        TransactionRow.Columns.date >= dateRange.lowerBound
          && TransactionRow.Columns.date <= dateRange.upperBound)
    }
    return request
  }

  private static func applyingPayeeFilter(
    to request: QueryInterfaceRequest<TransactionRow>,
    payee: String?
  ) -> QueryInterfaceRequest<TransactionRow> {
    guard let payee, !payee.isEmpty else { return request }
    let pattern = "%" + payee.lowercased() + "%"
    return request.filter(sql: "lower(payee) LIKE ?", arguments: [pattern])
  }
}
