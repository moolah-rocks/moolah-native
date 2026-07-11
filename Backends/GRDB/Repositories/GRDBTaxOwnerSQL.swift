import Foundation
import GRDB

enum GRDBTaxOwnerSQL {
  static func effectiveOwnerIdsExpression(defaultTaxOwnerId: UUID) -> SQL {
    let defaultOwnerId = defaultTaxOwnerId.uuidString
    return """
      COALESCE(
        NULLIF(c.tax_owner_ids_encoded, ''),
        NULLIF(a.tax_owner_ids_encoded, ''),
        \(defaultOwnerId)
      )
      """
  }
}
