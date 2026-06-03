import Foundation
import Testing

@testable import Moolah

@Suite("InsightDismissalRow mapping")
struct InsightDismissalRowMappingTests {
  @Test
  func domainRoundTrips() {
    let domain = InsightDismissal(kind: .subscriptionPriceHike, count: 3)
    let row = InsightDismissalRow(domain: domain)
    #expect(row.kind == InsightKind.subscriptionPriceHike.rawValue)
    #expect(row.count == 3)
    #expect(row.toDomain() == domain)
  }

  @Test
  func idIsDeterministicPerKind() {
    let recurring = InsightDismissalRow.id(for: .newRecurringDetected)
    let recurringAgain = InsightDismissalRow.id(for: .newRecurringDetected)
    let priceHike = InsightDismissalRow.id(for: .subscriptionPriceHike)
    #expect(recurring == recurringAgain)
    #expect(recurring != priceHike)
  }

  @Test
  func unknownKindProjectsNil() {
    var row = InsightDismissalRow(kind: .newRecurringDetected, count: 1)
    row.kind = "a_kind_this_build_does_not_know"
    #expect(row.toDomain() == nil)
  }
}
