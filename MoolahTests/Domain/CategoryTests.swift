import Foundation
import Testing

@testable import Moolah

@Suite("Category")
struct CategoryTests {
  @Test
  func defaultsToNotTaxReportable() {
    let category = Category(name: "Groceries")

    #expect(category.isTaxReportable == false)
    #expect(category.taxOwnerIds.isEmpty)
  }

  @Test
  func taxFieldsRoundTripViaCodable() throws {
    let ownerIds = [UUID(), UUID()]
    let category = Category(
      name: "Interest",
      isTaxReportable: true,
      taxOwnerIds: ownerIds)

    let encoded = try JSONEncoder().encode(category)
    let decoded = try JSONDecoder().decode(Category.self, from: encoded)

    #expect(decoded.isTaxReportable == true)
    #expect(decoded.taxOwnerIds == ownerIds)
  }

  @Test
  func legacyCategoryWithoutTaxFieldsDecodesWithDefaults() throws {
    let json = Data(
      """
      {"id":"\(UUID().uuidString)","name":"Legacy"}
      """.utf8)

    let decoded = try JSONDecoder().decode(Category.self, from: json)

    #expect(decoded.isTaxReportable == false)
    #expect(decoded.taxOwnerIds.isEmpty)
  }
}
