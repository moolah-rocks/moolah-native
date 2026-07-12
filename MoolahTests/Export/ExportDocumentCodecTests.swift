import Foundation
import Testing

@testable import Moolah

@Suite("Export document codec")
struct ExportDocumentCodecTests {
  @Test("version 2 writes full instruments only in the catalogue")
  func versionTwoUsesInstrumentReferences() throws {
    let fixture = makeMixedInstrumentFixture()

    let data = try ExportDocumentCodec().encode(fixture.data)
    let root = try jsonObject(from: data)

    #expect(root["version"] as? Int == 2)
    #expect((root["instruments"] as? [[String: Any]])?.count == fixture.data.instruments.count)

    let accounts = try #require(root["accounts"] as? [[String: Any]])
    #expect(accounts.first?["instrument"] as? String == fixture.stock.id)

    let groups = try #require(root["accountGroups"] as? [[String: Any]])
    #expect(groups.first?["instrument"] as? String == fixture.stock.id)

    let earmarks = try #require(root["earmarks"] as? [[String: Any]])
    let earmark = try #require(earmarks.first)
    #expect(earmark["instrument"] as? String == Instrument.USD.id)
    let savingsTarget = try #require(earmark["savingsTarget"] as? [String: Any])
    #expect(savingsTarget["instrument"] as? String == Instrument.USD.id)

    let budgets = try #require(root["earmarkBudgets"] as? [Any])
    let budgetItems = try #require(
      uuidDictionaryValue(in: budgets, for: fixture.earmarkId) as? [[String: Any]])
    let budget = try #require(budgetItems.first)
    let budgetAmount = try #require(budget["amount"] as? [String: Any])
    #expect(budgetAmount["instrument"] as? String == Instrument.USD.id)

    let transactions = try #require(root["transactions"] as? [[String: Any]])
    let legs = try #require(transactions.first?["legs"] as? [[String: Any]])
    #expect(legs.first?["instrument"] as? String == fixture.stock.id)

    let values = try #require(root["investmentValues"] as? [Any])
    let accountValues = try #require(
      uuidDictionaryValue(in: values, for: fixture.accountId) as? [[String: Any]])
    let value = try #require(accountValues.first?["value"] as? [String: Any])
    #expect(value["instrument"] as? String == fixture.crypto.id)
  }

  @Test("version 2 round trip preserves mixed instrument definitions and quantities")
  func versionTwoRoundTrip() throws {
    let fixture = makeMixedInstrumentFixture()

    let encoded = try ExportDocumentCodec().encode(fixture.data)
    let decoded = try ExportDocumentCodec().decode(encoded)

    #expect(decoded.version == 2)
    #expect(Set(decoded.instruments) == Set(fixture.data.instruments))
    #expect(decoded.accounts.first?.instrument == fixture.stock)
    #expect(decoded.accountGroups.first?.instrument == fixture.stock)
    #expect(decoded.earmarks.first?.instrument == Instrument.USD)
    #expect(decoded.earmarks.first?.savingsGoal?.quantity == dec("500"))
    #expect(decoded.earmarkBudgets[fixture.earmarkId]?.first?.amount.instrument == Instrument.USD)
    #expect(decoded.transactions.first?.notes == "Preserve ordinary transaction fields")
    #expect(decoded.transactions.first?.legs.first?.instrument == fixture.stock)
    #expect(decoded.transactions.first?.legs.first?.quantity == dec("10"))
    #expect(decoded.investmentValues[fixture.accountId]?.first?.value.instrument == fixture.crypto)
    #expect(decoded.investmentValues[fixture.accountId]?.first?.value.quantity == dec("2.5"))
  }

  @Test("version 1 export with embedded instruments still decodes")
  func versionOneStillDecodes() throws {
    let fixture = makeMixedInstrumentFixture(version: 1)
    let legacyData = try legacyEncoder().encode(fixture.data)

    let legacyRoot = try jsonObject(from: legacyData)
    let accounts = try #require(legacyRoot["accounts"] as? [[String: Any]])
    #expect(accounts.first?["instrument"] is [String: Any])

    let decoded = try ExportDocumentCodec().decode(legacyData)

    #expect(decoded.version == 1)
    #expect(decoded.accounts.first?.instrument == fixture.stock)
    #expect(decoded.investmentValues[fixture.accountId]?.first?.value.instrument == fixture.crypto)
    #expect(Set(decoded.instruments) == Set(fixture.data.instruments))
  }

  @Test("version 2 rejects a missing instrument reference")
  func missingReferenceFails() throws {
    let fixture = makeMixedInstrumentFixture()
    let encoded = try ExportDocumentCodec().encode(fixture.data)
    var root = try jsonObject(from: encoded)
    var accounts = try #require(root["accounts"] as? [[String: Any]])
    accounts[0]["instrument"] = "missing-instrument"
    root["accounts"] = accounts
    let corrupted = try JSONSerialization.data(withJSONObject: root)

    #expect(throws: DecodingError.self) {
      try ExportDocumentCodec().decode(corrupted)
    }
  }

  @Test("version 2 rejects conflicting catalogue definitions")
  func conflictingCatalogueFails() throws {
    let fixture = makeMixedInstrumentFixture()
    let encoded = try ExportDocumentCodec().encode(fixture.data)
    var root = try jsonObject(from: encoded)
    var instruments = try #require(root["instruments"] as? [[String: Any]])
    var conflict = try #require(instruments.first { $0["id"] as? String == fixture.stock.id })
    conflict["name"] = "Conflicting name"
    instruments.append(conflict)
    root["instruments"] = instruments
    let corrupted = try JSONSerialization.data(withJSONObject: root)

    #expect(throws: DecodingError.self) {
      try ExportDocumentCodec().decode(corrupted)
    }
  }

  @Test("encoding automatically discovers instruments missing from the initial catalogue")
  func missingCatalogueEntryIsDiscovered() throws {
    let fixture = makeMixedInstrumentFixture()
    let incomplete = ExportedData(
      version: 2,
      exportedAt: fixture.data.exportedAt,
      profileLabel: fixture.data.profileLabel,
      currencyCode: fixture.data.currencyCode,
      financialYearStartMonth: fixture.data.financialYearStartMonth,
      instruments: [Instrument.AUD],
      accounts: fixture.data.accounts,
      accountGroups: fixture.data.accountGroups,
      categories: fixture.data.categories,
      earmarks: fixture.data.earmarks,
      earmarkBudgets: fixture.data.earmarkBudgets,
      transactions: fixture.data.transactions,
      investmentValues: fixture.data.investmentValues
    )

    let encoded = try ExportDocumentCodec().encode(incomplete)
    let decoded = try ExportDocumentCodec().decode(encoded)

    #expect(Set(decoded.instruments) == Set(fixture.data.instruments))
    #expect(decoded.accounts.first?.instrument == fixture.stock)
    #expect(decoded.investmentValues[fixture.accountId]?.first?.value.instrument == fixture.crypto)
  }

  @Test("version 2 cannot be encoded without the export document codec")
  func contextFreeVersionTwoEncodingFails() throws {
    let fixture = makeMixedInstrumentFixture()

    #expect(throws: EncodingError.self) {
      try legacyEncoder().encode(fixture.data)
    }
  }

  @Test("version 2 cannot be decoded without the export document codec")
  func contextFreeVersionTwoDecodingFails() throws {
    let encoded = try ExportDocumentCodec().encode(makeMixedInstrumentFixture().data)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    #expect(throws: DecodingError.self) {
      try decoder.decode(ExportedData.self, from: encoded)
    }
  }

  @Test("instrument references materially reduce a large investment history export")
  func versionTwoIsMateriallySmaller() throws {
    let stock = Instrument.stock(
      ticker: "BHP.AX", exchange: "ASX", name: "BHP Group Limited", decimals: 4)
    let accountId = UUID()
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let values = (0..<500).map { offset in
      InvestmentValue(
        date: start.addingTimeInterval(TimeInterval(offset * 86_400)),
        value: InstrumentAmount(quantity: Decimal(offset) / 10, instrument: stock)
      )
    }
    let legacy = makeInvestmentHistory(
      version: 1, accountId: accountId, instrument: stock, values: values)
    let current = makeInvestmentHistory(
      version: 2, accountId: accountId, instrument: stock, values: values)

    let legacySize = try legacyEncoder().encode(legacy).count
    let currentSize = try ExportDocumentCodec().encode(current).count

    #expect(currentSize < legacySize * 3 / 5)
  }
}

extension ExportDocumentCodecTests {
  fileprivate struct MixedInstrumentFixture {
    let data: ExportedData
    let accountId: UUID
    let earmarkId: UUID
    let stock: Instrument
    let crypto: Instrument
  }

  fileprivate struct MixedFixtureIds {
    let accountId = UUID()
    let groupId = UUID()
    let earmarkId = UUID()
    let categoryId = UUID()
  }

  fileprivate func makeMixedInstrumentFixture(version: Int = 2) -> MixedInstrumentFixture {
    let ids = MixedFixtureIds()
    let stock = Instrument.stock(
      ticker: "BHP.AX", exchange: "ASX", name: "BHP Group Limited", decimals: 4)
    let crypto = Instrument.crypto(
      chainId: 1,
      contractAddress: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      symbol: "USDC",
      name: "USD Coin",
      decimals: 6
    )
    let data = ExportedData(
      version: version,
      exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
      profileLabel: "Mixed instruments",
      currencyCode: Instrument.AUD.id,
      financialYearStartMonth: 7,
      instruments: [Instrument.AUD, Instrument.USD, stock, crypto],
      accounts: makeFixtureAccounts(ids: ids, stock: stock),
      accountGroups: makeFixtureGroups(ids: ids, stock: stock),
      categories: [Category(id: ids.categoryId, name: "Investing")],
      earmarks: makeFixtureEarmarks(ids: ids),
      earmarkBudgets: makeFixtureBudgets(ids: ids),
      transactions: makeFixtureTransactions(ids: ids, stock: stock),
      investmentValues: makeFixtureInvestmentValues(ids: ids, crypto: crypto)
    )
    return MixedInstrumentFixture(
      data: data,
      accountId: ids.accountId,
      earmarkId: ids.earmarkId,
      stock: stock,
      crypto: crypto)
  }

  fileprivate func makeFixtureAccounts(ids: MixedFixtureIds, stock: Instrument) -> [Account] {
    [
      Account(
        id: ids.accountId,
        name: "Brokerage",
        type: .investment,
        instrument: stock,
        groupId: ids.groupId)
    ]
  }

  fileprivate func makeFixtureGroups(ids: MixedFixtureIds, stock: Instrument) -> [AccountGroup] {
    [
      AccountGroup(
        id: ids.groupId,
        name: "Long term",
        bucket: .investments,
        instrument: stock)
    ]
  }

  fileprivate func makeFixtureEarmarks(ids: MixedFixtureIds) -> [Earmark] {
    [
      Earmark(
        id: ids.earmarkId,
        name: "US trip",
        instrument: .USD,
        savingsGoal: InstrumentAmount(quantity: dec("500"), instrument: .USD))
    ]
  }

  fileprivate func makeFixtureBudgets(ids: MixedFixtureIds) -> [UUID: [EarmarkBudgetItem]] {
    [
      ids.earmarkId: [
        EarmarkBudgetItem(
          categoryId: ids.categoryId,
          amount: InstrumentAmount(quantity: dec("50"), instrument: .USD))
      ]
    ]
  }

  fileprivate func makeFixtureTransactions(ids: MixedFixtureIds, stock: Instrument) -> [Transaction]
  {
    [
      Transaction(
        date: Date(timeIntervalSince1970: 1_700_100_000),
        payee: "Buy BHP",
        notes: "Preserve ordinary transaction fields",
        legs: [
          TransactionLeg(
            accountId: ids.accountId,
            instrument: stock,
            quantity: dec("10"),
            type: .income,
            categoryId: ids.categoryId)
        ])
    ]
  }

  fileprivate func makeFixtureInvestmentValues(
    ids: MixedFixtureIds,
    crypto: Instrument
  ) -> [UUID: [InvestmentValue]] {
    [
      ids.accountId: [
        InvestmentValue(
          date: Date(timeIntervalSince1970: 1_700_200_000),
          value: InstrumentAmount(quantity: dec("2.5"), instrument: crypto))
      ]
    ]
  }

  fileprivate func makeInvestmentHistory(
    version: Int,
    accountId: UUID,
    instrument: Instrument,
    values: [InvestmentValue]
  ) -> ExportedData {
    ExportedData(
      version: version,
      exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
      profileLabel: "Large history",
      currencyCode: Instrument.AUD.id,
      financialYearStartMonth: 7,
      instruments: [Instrument.AUD, instrument],
      accounts: [
        Account(
          id: accountId,
          name: "Brokerage",
          type: .investment,
          instrument: instrument)
      ],
      categories: [],
      earmarks: [],
      earmarkBudgets: [:],
      transactions: [],
      investmentValues: [accountId: values]
    )
  }

  fileprivate func legacyEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }

  fileprivate func jsonObject(from data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  fileprivate func uuidDictionaryValue(in encoded: [Any], for key: UUID) -> Any? {
    var index = 0
    while index + 1 < encoded.count {
      if let candidate = encoded[index] as? String,
        candidate.caseInsensitiveCompare(key.uuidString) == .orderedSame
      {
        return encoded[index + 1]
      }
      index += 2
    }
    return nil
  }
}
