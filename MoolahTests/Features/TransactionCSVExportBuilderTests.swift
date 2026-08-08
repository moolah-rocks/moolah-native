import Foundation
import Testing

@testable import Moolah

@Suite("Transaction CSV export builder")
struct TransactionCSVExportBuilderTests {
  @Test("exports every leg with names and synced-account metadata")
  func exportsEveryLegWithSyncedMetadata() async throws {
    let walletId = UUID()
    let category = Category(name: "Living", parentId: nil)
    let child = Category(name: "Groceries", parentId: category.id)
    let earmark = Earmark(name: "Holiday", instrument: .defaultTestInstrument)
    let wallet = Account(
      id: walletId,
      name: "Ethereum Wallet",
      type: .crypto,
      instrument: .defaultTestInstrument,
      walletAddress: "0xwallet",
      chainId: 1)
    let transactionId = UUID()
    let transaction = Transaction(
      id: transactionId,
      date: try #require(ISO8601DateFormatter().date(from: "2026-08-01T12:34:56Z")),
      payee: "Merchant, Inc.",
      notes: "First line\nSecond line",
      legs: [
        TransactionLeg(
          accountId: walletId,
          instrument: .defaultTestInstrument,
          quantity: -12.5,
          externalId: "0xabc:erc20:0",
          counterpartyAddress: "0xcounterparty",
          type: .expense,
          categoryId: child.id,
          earmarkId: earmark.id),
        TransactionLeg(
          accountId: walletId,
          instrument: .defaultTestInstrument,
          quantity: -0.01,
          externalId: "0xabc:gas",
          type: .expense),
      ])
    let context = TransactionCSVExportContext(
      filter: TransactionFilter(accountId: walletId),
      searchText: "",
      includesSpam: true,
      spamInstruments: [],
      timeZone: .utc,
      accounts: Accounts(from: [wallet]),
      categories: Categories(from: [category, child]),
      earmarks: Earmarks(from: [earmark]))

    let csv = try await TransactionCSVExportBuilder.csv(for: [transaction], context: context)

    let rows = try CSVTokenizer.parse(Data(csv.utf8))
    #expect(rows.count == 3)
    #expect(rows[0] == TransactionCSVExportBuilder.headers)
    assertFirstLeg(rows[1], transactionId: transactionId)
    #expect(rows[2][16] == "0xabc")
    #expect(rows[2][17] == "https://etherscan.io/tx/0xabc")
  }

  @Test("applies payee search and hidden-spam rules to the complete input")
  func appliesListProjectionRules() async throws {
    let accountId = UUID()
    let ordinary = Instrument.defaultTestInstrument
    let spam = Instrument.crypto(
      chainId: 1,
      contractAddress: "0x0000000000000000000000000000000000000001",
      symbol: "SPAM",
      name: "Spam",
      decimals: 18)
    let transactions = [
      transaction(payee: "Coffee Shop", accountId: accountId, instrument: ordinary),
      transaction(payee: "Coffee Airdrop", accountId: accountId, instrument: spam),
      transaction(payee: "Bakery", accountId: accountId, instrument: ordinary),
    ]
    let context = TransactionCSVExportContext(
      filter: TransactionFilter(accountId: accountId),
      searchText: "coffee",
      includesSpam: false,
      spamInstruments: [spam],
      timeZone: .utc,
      accounts: Accounts(from: []),
      categories: Categories(from: []),
      earmarks: Earmarks(from: []))

    let csv = try await TransactionCSVExportBuilder.csv(for: transactions, context: context)

    #expect(csv.contains("Coffee Shop"))
    #expect(!csv.contains("Coffee Airdrop"))
    #expect(!csv.contains("Bakery"))
  }

  @Test("exports the visible local calendar day across timezone boundaries")
  func exportsLocalCalendarDay() async throws {
    let cases = [
      ("2026-08-01T15:30:00Z", "America/Los_Angeles", "2026-08-01"),
      ("2026-08-01T15:30:00Z", "UTC", "2026-08-01"),
      ("2026-08-01T15:30:00Z", "Australia/Brisbane", "2026-08-02"),
      ("2026-08-01T15:30:00Z", "Pacific/Kiritimati", "2026-08-02"),
      ("2026-08-01T02:00:00Z", "America/Los_Angeles", "2026-07-31"),
      ("2026-08-01T02:00:00Z", "UTC", "2026-08-01"),
      ("2026-08-01T02:00:00Z", "Australia/Brisbane", "2026-08-01"),
      ("2026-08-01T02:00:00Z", "Pacific/Kiritimati", "2026-08-01"),
    ]

    for (instant, timeZoneIdentifier, expectedDate) in cases {
      let date = try #require(ISO8601DateFormatter().date(from: instant))
      let timeZone = try #require(TimeZone(identifier: timeZoneIdentifier))
      let transaction = transaction(
        payee: "Timezone boundary",
        accountId: UUID(),
        instrument: .defaultTestInstrument,
        date: date)
      let context = TransactionCSVExportContext(
        filter: TransactionFilter(),
        searchText: "",
        includesSpam: true,
        spamInstruments: [],
        timeZone: timeZone,
        accounts: Accounts(from: []),
        categories: Categories(from: []),
        earmarks: Earmarks(from: []))

      let csv = try await TransactionCSVExportBuilder.csv(for: [transaction], context: context)
      let rows = try CSVTokenizer.parse(Data(csv.utf8))

      #expect(rows[1][0] == expectedDate)
    }
  }
}

extension TransactionCSVExportBuilderTests {
  private func assertFirstLeg(_ row: [String], transactionId: UUID) {
    #expect(row[0] == "2026-08-01")
    #expect(row[1] == "Merchant, Inc.")
    #expect(row[2] == "First line\nSecond line")
    #expect(row[3] == transactionId.uuidString.lowercased())
    #expect(row[6] == "Ethereum Wallet")
    #expect(row[9] == "-12.5")
    #expect(row[11] == "expense")
    #expect(row[12] == "Living:Groceries")
    #expect(row[13] == "Holiday")
    #expect(row[15] == "0xcounterparty")
    #expect(row[16] == "0xabc")
    #expect(row[17] == "https://etherscan.io/tx/0xabc")
  }

  private func transaction(
    payee: String,
    accountId: UUID,
    instrument: Instrument,
    date: Date = Date(timeIntervalSince1970: 0)
  ) -> Transaction {
    Transaction(
      date: date,
      payee: payee,
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: instrument,
          quantity: -1,
          type: .expense)
      ])
  }
}
