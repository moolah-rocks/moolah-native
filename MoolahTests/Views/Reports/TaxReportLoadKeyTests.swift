import Foundation
import Testing

@testable import Moolah

@Suite("Tax report load invalidation")
struct TaxReportLoadKeyTests {
  @Test("a tax-relevant transaction change invalidates the visible report")
  func transactionChangeInvalidatesReport() {
    let ownerId = UUID()
    let initial = TaxReportLoadKey(
      report: .capitalGains,
      financialYear: 2026,
      spamInstruments: [],
      defaultTaxOwnerId: ownerId,
      ownerInvalidation: 0,
      transactionInvalidation: 1)
    let afterEdit = TaxReportLoadKey(
      report: .capitalGains,
      financialYear: 2026,
      spamInstruments: [],
      defaultTaxOwnerId: ownerId,
      ownerInvalidation: 0,
      transactionInvalidation: 2)

    #expect(initial != afterEdit)
  }
}
