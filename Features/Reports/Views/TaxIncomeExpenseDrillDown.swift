import Foundation

struct TaxIncomeExpenseDrillDown: Hashable {
  let kind: TaxIncomeExpenseDrillDownKind
  let ownerId: UUID?
  let ownerName: String?
  let dateInterval: Range<Date>
  let defaultTaxOwnerId: UUID

  var title: String {
    guard let ownerName else { return kind.title }
    return "\(kind.title) for \(ownerName)"
  }
}
