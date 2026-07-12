import Foundation
import Testing

@testable import Moolah

@Suite("ExportedData")
struct ExportedDataTests {

  private let instrument = Instrument.defaultTestInstrument

  @Test("JSON round-trip preserves all fields")
  func jsonRoundTrip() throws {
    let accountId = UUID()
    let categoryId = UUID()
    let earmarkId = UUID()
    let exportDate = Date(timeIntervalSince1970: 1_700_000_000)

    let original = Self.makeSingleCurrencyFixture(
      accountId: accountId,
      categoryId: categoryId,
      earmarkId: earmarkId,
      exportedAt: exportDate,
      instrument: instrument)

    let data = try ExportDocumentCodec().encode(original)
    let decoded = try ExportDocumentCodec().decode(data)

    #expect(decoded.version == original.version)
    #expect(decoded.exportedAt == original.exportedAt)
    #expect(decoded.profileLabel == original.profileLabel)
    #expect(decoded.currencyCode == original.currencyCode)
    #expect(decoded.financialYearStartMonth == original.financialYearStartMonth)
    #expect(decoded.accounts.count == original.accounts.count)
    #expect(decoded.accounts.first?.id == accountId)
    #expect(decoded.accounts.first?.name == "Checking")
    #expect(decoded.categories.count == original.categories.count)
    #expect(decoded.categories.first?.id == categoryId)
    #expect(decoded.earmarks.count == original.earmarks.count)
    #expect(decoded.earmarks.first?.id == earmarkId)
    #expect(decoded.earmarkBudgets[earmarkId]?.count == 1)
    #expect(decoded.transactions.count == original.transactions.count)
    #expect(decoded.investmentValues.isEmpty)
  }

  private static func makeSingleCurrencyFixture(
    accountId: UUID,
    categoryId: UUID,
    earmarkId: UUID,
    exportedAt: Date,
    instrument: Instrument
  ) -> ExportedData {
    ExportedData(
      version: ExportFormatVersion.current,
      exportedAt: exportedAt,
      profileLabel: "My Profile",
      currencyCode: "AUD",
      financialYearStartMonth: 7,
      instruments: [instrument],
      accounts: [
        Account(
          id: accountId, name: "Checking", type: .bank,
          instrument: instrument
        )
      ],
      categories: [
        Category(id: categoryId, name: "Food")
      ],
      earmarks: [
        Earmark(
          id: earmarkId, name: "Holiday",
          instrument: instrument
        )
      ],
      earmarkBudgets: [
        earmarkId: [
          EarmarkBudgetItem(
            categoryId: categoryId,
            amount: InstrumentAmount(quantity: dec("10.00"), instrument: instrument)
          )
        ]
      ],
      transactions: [
        Transaction(
          date: Date(),
          payee: "Employer",
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: instrument,
              quantity: dec("50.00"), type: .income
            )
          ]
        )
      ],
      investmentValues: [:]
    )
  }

  @Test("version field is present in JSON output")
  func versionFieldInJSON() throws {
    let exported = ExportedData(
      version: ExportFormatVersion.current,
      exportedAt: Date(),
      profileLabel: "Test",
      currencyCode: "USD",
      financialYearStartMonth: 1,
      accounts: [],
      categories: [],
      earmarks: [],
      earmarkBudgets: [:],
      transactions: [],
      investmentValues: [:]
    )

    let data = try ExportDocumentCodec().encode(exported)
    let object = try JSONSerialization.jsonObject(with: data)
    let json = try #require(object as? [String: Any])

    #expect(json["version"] as? Int == ExportFormatVersion.current)
    #expect(json["profileLabel"] as? String == "Test")
    #expect(json["currencyCode"] as? String == "USD")
    #expect(json["financialYearStartMonth"] as? Int == 1)
  }
}
