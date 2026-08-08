import Foundation
import Testing

@testable import Moolah

@Suite("Transaction CSV export builder")
struct TransactionCSVExportBuilderTests {
  @Test("exports every leg with names and synced-account metadata")
  func exportsEveryLegWithSyncedMetadata() async throws {
    let fixture = try syncedExportFixture()

    let csv = try await TransactionCSVExportBuilder.csv(
      for: [fixture.transaction], context: fixture.context)

    let rows = try CSVTokenizer.parse(Data(csv.utf8))
    try #require(rows.count == 3)
    assertHeaders(rows[0])
    assertInternalIDsAreAbsent(fixture.internalIds, from: csv)
    assertFirstLeg(rows[1])
    assertSecondLeg(rows[2])
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

      try #require(rows.count >= 2)
      #expect(rows[1][0] == expectedDate)
    }
  }

  @Test("prefers an account chain and falls back to the instrument chain")
  func resolvesExportChain() async throws {
    let cases = [
      ExportChainCase(
        accountChainId: 10,
        expectedChain: "10",
        expectedURL: "https://optimistic.etherscan.io/tx/0xabc"),
      ExportChainCase(
        accountChainId: nil,
        expectedChain: "1",
        expectedURL: "https://etherscan.io/tx/0xabc"),
    ]

    for testCase in cases {
      let row = try await syncedNativeAssetRow(accountChainId: testCase.accountChainId)

      try #require(row.count > 12)
      #expect(row[5] == testCase.expectedChain)
      #expect(row[12] == testCase.expectedURL)
    }
  }
}

// MARK: - Assertions and Fixtures

extension TransactionCSVExportBuilderTests {
  private func assertHeaders(_ row: [String]) {
    #expect(
      row == [
        "Date", "Payee", "Account", "Amount", "Instrument", "Chain ID",
        "ERC20 Contract Address", "Transaction Type", "Category", "Earmark",
        "On-chain Counterparty", "On-chain Transaction ID", "Block Explorer Link", "Notes",
      ])
  }

  private func assertInternalIDsAreAbsent(_ ids: [UUID], from csv: String) {
    for id in ids {
      #expect(!csv.contains(id.uuidString.lowercased()))
    }
  }

  private func assertFirstLeg(_ row: [String]) {
    #expect(
      row == [
        "2026-08-01", "Merchant, Inc.", "Ethereum Wallet", "-12.5",
        "USD Coin (USDC)", "1", "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", "expense",
        "Groceries", "Holiday", "0xcounterparty", "0xabc",
        "https://etherscan.io/tx/0xabc", "First line\nSecond line",
      ])
  }

  private func assertSecondLeg(_ row: [String]) {
    #expect(
      row == [
        "2026-08-01", "Merchant, Inc.", "Ethereum Wallet", "-0.01",
        "Ethereum (ETH)", "1", "", "expense", "", "", "", "0xabc",
        "https://etherscan.io/tx/0xabc", "First line\nSecond line",
      ])
  }

  private func syncedExportFixture() throws -> SyncedExportFixture {
    let ids = SyncedTransactionIDs()
    let parent = Category(id: ids.parentCategory, name: "Living", parentId: nil)
    let category = Category(id: ids.category, name: "Groceries", parentId: parent.id)
    let earmark = Earmark(
      id: ids.earmark,
      name: "Holiday",
      instrument: .defaultTestInstrument)
    let instruments = cryptoInstruments()
    let wallet = Account(
      id: ids.wallet,
      name: "Ethereum Wallet",
      type: .crypto,
      instrument: instruments.ethereum,
      walletAddress: "0xwallet",
      chainId: 1)
    let transaction = try syncedTransaction(
      ids: ids, earmarkId: earmark.id, instruments: instruments)
    let context = TransactionCSVExportContext(
      filter: TransactionFilter(accountId: ids.wallet),
      searchText: "",
      includesSpam: true,
      spamInstruments: [],
      timeZone: .utc,
      accounts: Accounts(from: [wallet]),
      categories: Categories(from: [parent, category]),
      earmarks: Earmarks(from: [earmark]))
    return SyncedExportFixture(
      transaction: transaction,
      context: context,
      internalIds: ids.all)
  }

  private func cryptoInstruments() -> (ethereum: Instrument, usdCoin: Instrument) {
    let ethereum = Instrument.crypto(
      chainId: 1,
      contractAddress: nil,
      symbol: "ETH",
      name: "Ethereum",
      decimals: 18)
    let usdCoin = Instrument.crypto(
      chainId: 1,
      contractAddress: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      symbol: "USDC",
      name: "USD Coin",
      decimals: 6)
    return (ethereum, usdCoin)
  }

  private func syncedNativeAssetRow(accountChainId: Int?) async throws -> [String] {
    let accountId = makeUUID("00000000-0000-0000-0000-000000000008")
    let ethereum = cryptoInstruments().ethereum
    let account = Account(
      id: accountId,
      name: "Wallet",
      type: accountChainId == nil ? .bank : .crypto,
      instrument: ethereum,
      walletAddress: accountChainId == nil ? nil : "0xwallet",
      chainId: accountChainId)
    let transaction = Transaction(
      date: Date(timeIntervalSince1970: 0),
      payee: "Transfer",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: ethereum,
          quantity: -1,
          externalId: "0xabc",
          type: .expense)
      ])
    let context = TransactionCSVExportContext(
      filter: TransactionFilter(accountId: accountId),
      searchText: "",
      includesSpam: true,
      spamInstruments: [],
      timeZone: .utc,
      accounts: Accounts(from: [account]),
      categories: Categories(from: []),
      earmarks: Earmarks(from: []))

    let csv = try await TransactionCSVExportBuilder.csv(for: [transaction], context: context)
    let rows = try CSVTokenizer.parse(Data(csv.utf8))
    try #require(rows.count >= 2)
    return rows[1]
  }

  private func syncedTransaction(
    ids: SyncedTransactionIDs,
    earmarkId: UUID,
    instruments: (ethereum: Instrument, usdCoin: Instrument)
  ) throws -> Transaction {
    Transaction(
      id: ids.transaction,
      date: try #require(ISO8601DateFormatter().date(from: "2026-08-01T12:34:56Z")),
      payee: "Merchant, Inc.",
      notes: "First line\nSecond line",
      legs: [
        TransactionLeg(
          id: ids.tokenLeg,
          accountId: ids.wallet,
          instrument: instruments.usdCoin,
          quantity: -12.5,
          externalId: "0xabc:erc20:0",
          counterpartyAddress: "0xcounterparty",
          type: .expense,
          categoryId: ids.category,
          earmarkId: earmarkId),
        TransactionLeg(
          id: ids.gasLeg,
          accountId: ids.wallet,
          instrument: instruments.ethereum,
          quantity: -0.01,
          externalId: "0xabc:gas",
          type: .expense),
      ])
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

// MARK: - Supporting Types

private struct SyncedExportFixture {
  let transaction: Transaction
  let context: TransactionCSVExportContext
  let internalIds: [UUID]
}

private struct ExportChainCase {
  let accountChainId: Int?
  let expectedChain: String
  let expectedURL: String
}

private struct SyncedTransactionIDs {
  let transaction = makeUUID("00000000-0000-0000-0000-000000000001")
  let tokenLeg = makeUUID("00000000-0000-0000-0000-000000000002")
  let gasLeg = makeUUID("00000000-0000-0000-0000-000000000003")
  let wallet = makeUUID("00000000-0000-0000-0000-000000000004")
  let parentCategory = makeUUID("00000000-0000-0000-0000-000000000005")
  let category = makeUUID("00000000-0000-0000-0000-000000000006")
  let earmark = makeUUID("00000000-0000-0000-0000-000000000007")

  var all: [UUID] {
    [transaction, tokenLeg, gasLeg, wallet, parentCategory, category, earmark]
  }
}
