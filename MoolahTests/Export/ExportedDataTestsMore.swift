import Foundation
import Testing

@testable import Moolah

@Suite("ExportedData — Part 2")
struct ExportedDataTestsMore {
  @Test("default metadata values for backward compatibility")
  func defaultMetadataValues() {
    let exported = ExportedData(
      accounts: [],
      categories: [],
      earmarks: [],
      earmarkBudgets: [:],
      transactions: [],
      investmentValues: [:]
    )

    #expect(exported.version == ExportFormatVersion.current)
    #expect(exported.profileLabel.isEmpty)
    #expect(exported.currencyCode.isEmpty)
    #expect(exported.financialYearStartMonth == 1)
  }

  @Test("JSON round-trip preserves mixed-currency instruments on accounts, legs, and earmarks")
  func multiCurrencyRoundTrip() throws {
    let ids = MultiCurrencyFixtureIds()
    let original = Self.makeMultiCurrencyFixture(ids: ids)

    let data = try ExportDocumentCodec().encode(original)
    let decoded = try ExportDocumentCodec().decode(data)

    let aud = Instrument.AUD
    let usd = Instrument.USD
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)

    // Instruments list preserved (all four kinds: two fiat, stock, crypto)
    let decodedInstrumentsById = Dictionary(
      uniqueKeysWithValues: decoded.instruments.map { ($0.id, $0) })
    #expect(decoded.instruments.count == 4)
    #expect(decodedInstrumentsById[aud.id] == aud)
    #expect(decodedInstrumentsById[usd.id] == usd)
    #expect(decodedInstrumentsById[bhp.id] == bhp)
    #expect(decodedInstrumentsById[eth.id] == eth)

    // Accounts keep their instruments (fiat, stock, and crypto)
    let decodedAccountsById = Dictionary(uniqueKeysWithValues: decoded.accounts.map { ($0.id, $0) })
    #expect(decodedAccountsById[ids.audAccountId]?.instrument == aud)
    #expect(decodedAccountsById[ids.usdAccountId]?.instrument == usd)
    #expect(decodedAccountsById[ids.investmentAccountId]?.instrument == bhp)
    #expect(decodedAccountsById[ids.cryptoEarmarkAccountId]?.instrument == eth)

    // Earmark and its savings goal stay on the foreign fiat
    let decodedEarmark = decoded.earmarks.first { $0.id == ids.earmarkId }
    #expect(decodedEarmark?.instrument == usd)
    #expect(decodedEarmark?.savingsGoal?.instrument == usd)

    // Budget item stays on the earmark's instrument
    let decodedBudget = decoded.earmarkBudgets[ids.earmarkId]?.first
    #expect(decodedBudget?.amount.instrument == usd)

    // Legs carry through their full kind-specific metadata
    let legInstruments = decoded.transactions.flatMap { $0.legs.map(\.instrument) }
    #expect(Set(legInstruments) == Set([aud, usd, bhp, eth]))

    let stockLeg = decoded.transactions
      .flatMap { $0.legs }
      .first { $0.instrument.kind == .stock }
    #expect(stockLeg?.instrument.ticker == "BHP.AX")
    #expect(stockLeg?.instrument.exchange == "ASX")

    let cryptoLeg = decoded.transactions
      .flatMap { $0.legs }
      .first { $0.instrument.kind == .cryptoToken }
    #expect(cryptoLeg?.instrument.chainId == 1)
    #expect(cryptoLeg?.instrument.ticker == "ETH")
    #expect(cryptoLeg?.instrument.decimals == 18)

    // Investment values keep their instrument
    let decodedStockValues = decoded.investmentValues[ids.investmentAccountId]
    #expect(decodedStockValues?.first?.value.instrument == bhp)
    let decodedCryptoValues = decoded.investmentValues[ids.cryptoEarmarkAccountId]
    #expect(decodedCryptoValues?.first?.value.instrument == eth)
  }

  private struct MultiCurrencyFixtureIds {
    let audAccountId = UUID()
    let usdAccountId = UUID()
    let investmentAccountId = UUID()
    let cryptoEarmarkAccountId = UUID()
    let earmarkId = UUID()
    let foodCategoryId = UUID()
  }

  private static func makeMultiCurrencyFixture(ids: MultiCurrencyFixtureIds) -> ExportedData {
    let aud = Instrument.AUD
    let usd = Instrument.USD
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)

    return ExportedData(
      version: ExportFormatVersion.current,
      exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
      profileLabel: "Multi-currency profile",
      currencyCode: aud.id,
      financialYearStartMonth: 7,
      instruments: [aud, usd, bhp, eth],
      accounts: makeMultiCurrencyAccounts(ids: ids, aud: aud, usd: usd, bhp: bhp, eth: eth),
      categories: [Category(id: ids.foodCategoryId, name: "Food")],
      earmarks: [
        Earmark(
          id: ids.earmarkId, name: "US Trip", instrument: usd,
          savingsGoal: InstrumentAmount(quantity: dec("500"), instrument: usd)
        )
      ],
      earmarkBudgets: [
        ids.earmarkId: [
          EarmarkBudgetItem(
            categoryId: ids.foodCategoryId,
            amount: InstrumentAmount(quantity: dec("50"), instrument: usd)
          )
        ]
      ],
      transactions: makeMultiCurrencyTransactions(ids: ids, aud: aud, usd: usd, bhp: bhp, eth: eth),
      investmentValues: makeMultiCurrencyInvestmentValues(ids: ids, bhp: bhp, eth: eth)
    )
  }

  private static func makeMultiCurrencyAccounts(
    ids: MultiCurrencyFixtureIds,
    aud: Instrument,
    usd: Instrument,
    bhp: Instrument,
    eth: Instrument
  ) -> [Account] {
    [
      Account(id: ids.audAccountId, name: "Checking AUD", type: .bank, instrument: aud),
      Account(id: ids.usdAccountId, name: "USD Travel", type: .bank, instrument: usd),
      Account(id: ids.investmentAccountId, name: "Brokerage", type: .investment, instrument: bhp),
      Account(id: ids.cryptoEarmarkAccountId, name: "Crypto Wallet", type: .asset, instrument: eth),
    ]
  }

  private static func makeMultiCurrencyTransactions(
    ids: MultiCurrencyFixtureIds,
    aud: Instrument,
    usd: Instrument,
    bhp: Instrument,
    eth: Instrument
  ) -> [Transaction] {
    [
      Transaction(
        date: Date(timeIntervalSince1970: 1_700_100_000),
        payee: "Coffee shop NYC",
        legs: [
          TransactionLeg(
            accountId: ids.usdAccountId, instrument: usd,
            quantity: dec("-4.50"), type: .expense,
            categoryId: ids.foodCategoryId, earmarkId: ids.earmarkId
          )
        ]
      ),
      Transaction(
        date: Date(timeIntervalSince1970: 1_700_200_000),
        payee: "Stock purchase",
        legs: [
          TransactionLeg(
            accountId: ids.audAccountId, instrument: aud,
            quantity: dec("-1500.00"), type: .transfer
          ),
          TransactionLeg(
            accountId: ids.investmentAccountId, instrument: bhp,
            quantity: dec("10"), type: .transfer
          ),
        ]
      ),
      Transaction(
        date: Date(timeIntervalSince1970: 1_700_300_000),
        payee: "Crypto swap",
        legs: [
          TransactionLeg(
            accountId: ids.cryptoEarmarkAccountId, instrument: eth,
            quantity: dec("0.25"), type: .income
          )
        ]
      ),
    ]
  }

  private static func makeMultiCurrencyInvestmentValues(
    ids: MultiCurrencyFixtureIds, bhp: Instrument, eth: Instrument
  ) -> [UUID: [InvestmentValue]] {
    [
      ids.investmentAccountId: [
        InvestmentValue(
          date: Date(timeIntervalSince1970: 1_700_400_000),
          value: InstrumentAmount(quantity: dec("10"), instrument: bhp)
        )
      ],
      ids.cryptoEarmarkAccountId: [
        InvestmentValue(
          date: Date(timeIntervalSince1970: 1_700_500_000),
          value: InstrumentAmount(quantity: dec("0.25"), instrument: eth)
        )
      ],
    ]
  }
}
