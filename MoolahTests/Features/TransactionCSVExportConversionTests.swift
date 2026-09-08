import Foundation
import Testing

@testable import Moolah

@Suite("Transaction CSV export conversion")
struct TransactionCSVExportConversionTests {
  @Test("exports transaction-date values in the profile base currency")
  func exportsHistoricBaseCurrencyValues() async throws {
    let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
    let secondDate = Date(timeIntervalSince1970: 1_710_000_000)
    let usdTransaction = transaction(payee: "USD purchase", instrument: .USD, date: firstDate)
    let audTransaction = transaction(payee: "AUD purchase", instrument: .AUD, date: secondDate)
    let conversionService = FakeConversionService.dateRates([
      firstDate: [Instrument.USD.id: Decimal(15) / Decimal(10)],
      secondDate: [Instrument.USD.id: Decimal(2)],
    ])

    let csv = try await TransactionCSVExportBuilder.csv(
      for: [usdTransaction, audTransaction],
      context: context(),
      baseInstrument: .AUD,
      conversionService: conversionService)

    let rows = try CSVTokenizer.parse(Data(csv.utf8))
    try #require(rows.count == 3)
    #expect(rows[0][5] == "Base Currency Amount (AUD)")
    #expect(rows[1][3] == "-1")
    #expect(rows[1][5] == "-1.5")
    #expect(rows[2][3] == "-1")
    #expect(rows[2][5] == "-1")
    #expect(conversionService.recordedCalls.count == 1)
    #expect(conversionService.recordedCalls.first?.date == firstDate)
    #expect(conversionService.recordedBatches.count == 1)
    #expect(conversionService.recordedBatches.first?.count == 1)
  }

  @Test("exports a known-zero foreign amount as zero")
  func exportsKnownZeroBaseCurrencyValue() async throws {
    let spam = Instrument.crypto(
      chainId: 1,
      contractAddress: "0x0000000000000000000000000000000000000001",
      symbol: "SPAM",
      name: "Spam",
      decimals: 18)
    let conversionService = FakeConversionService.fixedRates([:], knownZero: [spam.id])

    let csv = try await TransactionCSVExportBuilder.csv(
      for: [transaction(payee: "Spam transfer", instrument: spam)],
      context: context(spamInstruments: [spam]),
      baseInstrument: .AUD,
      conversionService: conversionService)

    let rows = try CSVTokenizer.parse(Data(csv.utf8))
    try #require(rows.count == 2)
    #expect(rows[1][3] == "-1")
    #expect(rows[1][5] == "0")
    #expect(conversionService.recordedBatches.count == 1)
  }
}

extension TransactionCSVExportConversionTests {
  private func context(spamInstruments: Set<Instrument> = []) -> TransactionCSVExportContext {
    TransactionCSVExportContext(
      filter: TransactionFilter(),
      searchText: "",
      includesSpam: true,
      spamInstruments: spamInstruments,
      timeZone: .utc,
      accounts: Accounts(from: []),
      categories: Categories(from: []),
      earmarks: Earmarks(from: []))
  }

  private func transaction(payee: String, instrument: Instrument, date: Date = .distantPast)
    -> Transaction
  {
    Transaction(
      date: date,
      payee: payee,
      legs: [
        TransactionLeg(
          accountId: UUID(),
          instrument: instrument,
          quantity: -1,
          type: .expense)
      ])
  }
}
