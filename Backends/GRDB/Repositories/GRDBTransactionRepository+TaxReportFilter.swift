import Foundation
import GRDB

extension GRDBTransactionRepository {
  static func applyingTaxReportableFilter(
    to request: QueryInterfaceRequest<TransactionRow>,
    filter: TransactionFilter
  ) -> QueryInterfaceRequest<TransactionRow> {
    guard let legType = filter.taxReportableLegType else { return request }
    let predicate = taxReportableTransactionPredicate(
      legType: legType,
      ownerId: filter.taxOwnerId,
      defaultOwnerId: filter.taxDefaultOwnerId)
    return request.filter(sql: predicate.sql, arguments: predicate.arguments)
  }

  private static func taxReportableTransactionPredicate(
    legType: TransactionType,
    ownerId: UUID?,
    defaultOwnerId: UUID?
  ) -> (sql: String, arguments: StatementArguments) {
    guard let ownerId else {
      return allOwnerTaxReportablePredicate(legType: legType)
    }
    guard let defaultOwnerId else { return ("0", []) }
    return ownerTaxReportablePredicate(
      legType: legType,
      ownerId: ownerId,
      defaultOwnerId: defaultOwnerId)
  }

  private static func allOwnerTaxReportablePredicate(
    legType: TransactionType
  ) -> (sql: String, arguments: StatementArguments) {
    (
      """
      id IN (
        SELECT leg.transaction_id
        FROM transaction_leg leg
        JOIN category c ON leg.category_id = c.id
        WHERE c.is_tax_reportable = 1
          AND leg.type = ?
      )
      """,
      [legType.rawValue]
    )
  }

  private static func ownerTaxReportablePredicate(
    legType: TransactionType,
    ownerId: UUID,
    defaultOwnerId: UUID
  ) -> (sql: String, arguments: StatementArguments) {
    (
      """
      id IN (
        SELECT leg.transaction_id
        FROM transaction_leg leg
        JOIN category c ON leg.category_id = c.id
        LEFT JOIN account a ON leg.account_id = a.id
        WHERE c.is_tax_reportable = 1
          AND leg.type = ?
          AND instr(
            ',' || COALESCE(
              NULLIF(c.tax_owner_ids_encoded, ''),
              NULLIF(a.tax_owner_ids_encoded, ''),
              ?
            ) || ',',
            ',' || ? || ','
          ) > 0
      )
      """,
      [legType.rawValue, defaultOwnerId.uuidString, ownerId.uuidString]
    )
  }
}
