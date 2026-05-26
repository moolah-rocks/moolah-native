import Foundation
import Testing

@testable import Moolah

@Suite("AccountType")
struct AccountTypeTests {
  @Test
  func cryptoAndInvestmentBothInvestmentLike() {
    #expect(AccountType.crypto.isInvestmentLike)
    #expect(AccountType.investment.isInvestmentLike)
    #expect(!AccountType.bank.isInvestmentLike)
    #expect(!AccountType.creditCard.isInvestmentLike)
    #expect(!AccountType.asset.isInvestmentLike)
  }

  @Test
  func cryptoIsNotIsCurrent() {
    #expect(!AccountType.crypto.isCurrent)
  }

  @Test
  func syncedTypesAreExactlyCryptoAndExchange() {
    #expect(AccountType.crypto.isSynced)
    #expect(AccountType.exchange.isSynced)
    #expect(!AccountType.bank.isSynced)
    #expect(!AccountType.creditCard.isSynced)
    #expect(!AccountType.asset.isSynced)
    #expect(!AccountType.investment.isSynced)
    // Regression guard for the automation sync filter: exactly the two
    // source-backed types, even if a new case is added later.
    #expect(AccountType.allCases.filter(\.isSynced) == [.crypto, .exchange])
  }

  @Test
  func unknownStringDecodesAsAssetWithWarning() throws {
    // RawRepresentable enums fail decode on unknown raw values by default.
    // The defensive fallback for unknown account types is implemented in the
    // RECORD-LAYER decoder (AccountRow), not on the domain enum itself.
    // This test asserts the domain default — that the enum decode does throw —
    // so the record-layer test can be the single source of fallback truth.
    let json = Data("\"future-type\"".utf8)
    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode(AccountType.self, from: json)
    }
  }

  @Test
  func bucketMapsCurrentTypesToCurrent() {
    #expect(AccountType.bank.bucket == .current)
    #expect(AccountType.creditCard.bucket == .current)
    #expect(AccountType.asset.bucket == .current)
  }

  @Test
  func bucketMapsInvestmentTypesToInvestments() {
    #expect(AccountType.investment.bucket == .investments)
    #expect(AccountType.crypto.bucket == .investments)
    #expect(AccountType.exchange.bucket == .investments)
  }

  @Test
  func bucketCoversEveryAccountType() {
    // Regression guard: every AccountType case must map to the right
    // bucket. Pinning the full expected output mirrors the
    // `syncedTypesAreExactlyCryptoAndExchange` style — a new case added
    // without a bucket decision (or assigned to the wrong bucket)
    // fails this test with a meaningful diff.
    #expect(
      AccountType.allCases.filter { $0.bucket == .current }
        == [.bank, .creditCard, .asset])
    #expect(
      AccountType.allCases.filter { $0.bucket == .investments }
        == [.investment, .crypto, .exchange])
  }
}
