import Foundation
import GRDB

extension GRDBTransactionRepository {
  static func applyingTaxReportableFilter(
    to request: QueryInterfaceRequest<TransactionRow>,
    filter: TransactionFilter
  ) -> QueryInterfaceRequest<TransactionRow> {
    guard let legType = filter.taxReportableLegType else { return request }
    guard let ownerId = filter.taxOwnerId else {
      return request.filter(
        sql: """
          id IN (
            SELECT leg.transaction_id
            FROM transaction_leg leg
            JOIN category c ON leg.category_id = c.id
            WHERE c.is_tax_reportable = 1
              AND leg.type = ?
          )
          """,
        arguments: [legType.rawValue])
    }
    guard let defaultOwnerId = filter.taxDefaultOwnerId else {
      return request.filter(sql: "0")
    }
    let ownerIds = GRDBTaxOwnerSQL.effectiveOwnerIdsExpression(
      defaultTaxOwnerId: defaultOwnerId)
    let ownerIdString = ownerId.uuidString
    let legTypeRaw = legType.rawValue
    return request.filter(
      literal: """
        id IN (
          SELECT leg.transaction_id
          FROM transaction_leg leg
          JOIN category c ON leg.category_id = c.id
          LEFT JOIN account a ON leg.account_id = a.id
          WHERE c.is_tax_reportable = 1
            AND leg.type = \(legTypeRaw)
            AND instr(
              ',' || \(ownerIds) || ',',
              ',' || \(ownerIdString) || ','
            ) > 0
        )
        """)
  }
}
