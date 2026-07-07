import Foundation

struct TaxReportLoadDates {
  let valuationDate: Date
  let ledgerBeforeDate: Date?
  let sellDateInterval: Range<Date>?
}
