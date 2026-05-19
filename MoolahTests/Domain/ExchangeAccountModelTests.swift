import Testing

@testable import Moolah

struct ExchangeAccountModelTests {
  @Test
  func exchangeTypeIsSidebarGroupedWithInvestments() {
    #expect(AccountType.exchange.isInvestmentLike)
    #expect(!AccountType.exchange.isCurrent)
  }

  @Test
  func exchangeTypeRawValueIsStableToken() {
    #expect(AccountType.exchange.rawValue == "exchange")
  }

  @Test
  func exchangeTypeDisplayName() {
    #expect(AccountType.exchange.displayName == "Exchange")
  }

  @Test
  func exchangeTypeIsRegisteredInAllCases() {
    #expect(AccountType.allCases.contains(.exchange))
  }

  @Test
  func accountCarriesExchangeProvider() {
    let account = Account(
      name: "Coinstash", type: .exchange, instrument: .AUD,
      exchangeProvider: .coinstash)
    #expect(account.exchangeProvider == .coinstash)
  }

  @Test
  func dataFormatVersionBumpedForExchange() {
    #expect(DataFormatVersion.current >= 3)
  }
}
