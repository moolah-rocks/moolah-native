import Foundation
import GRDB
import Testing

@testable import Moolah

@MainActor
struct AccountDetailSeedRatesTests {
  @Test(arguments: ["America/Los_Angeles", "UTC", "Australia/Brisbane", "Pacific/Kiritimati"])
  func chartRatesAreAvailableWithoutAnyProviderRequests(zoneID: String) async throws {
    let zone = try #require(TimeZone(identifier: zoneID))
    let containers = try ProfileContainerManager.forTesting()
    _ = try UITestSeedHydrator.hydrate(.accountDetailLayout, into: containers)
    let client = AccountDetailForbiddenRates()
    let current = Date(timeIntervalSince1970: 1_792_540_801)
    let service = ExchangeRateService(
      client: client,
      database: containers.profileIndexDatabase,
      now: { current },
      timeZone: zone
    )
    let lower = UITestFixtures.AccountDetailLayout.multiCurrencyTxn1Date
    let usdToAUD = try await service.rates(from: .USD, to: .AUD, in: lower...current)
    let audToUSD = try await service.rates(from: .AUD, to: .USD, in: lower...current)
    #expect(!usdToAUD.isEmpty)
    #expect(usdToAUD.allSatisfy { $0.rate == Decimal(string: "1.5") })
    #expect(!audToUSD.isEmpty)
    #expect(await client.requests == 0)
  }
}

private actor AccountDetailForbiddenRates: ExchangeRateClient {
  var requests = 0

  func fetchRates(base: String, from: Date, to: Date) async throws -> [String: [String: Decimal]] {
    requests += 1
    throw URLError(.notConnectedToInternet)
  }
}

extension AccountDetailSeedRatesTests {
  @Test
  func failedSeedTransactionRollsBackEveryRateAndMetadataRow() throws {
    let containers = try ProfileContainerManager.forTesting()
    let database = containers.profileIndexDatabase
    #expect(throws: SeedFailure.rejected) {
      try database.write { database in
        try UITestSeedHydrator.seedAccountDetailExchangeRates(in: database)
        throw SeedFailure.rejected
      }
    }
    let counts = try database.read { database in
      (try ExchangeRateRecord.fetchCount(database), try ExchangeRateMetaRecord.fetchCount(database))
    }
    #expect(counts.0 == 0)
    #expect(counts.1 == 0)
  }
}

private enum SeedFailure: Error { case rejected }
