import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("CryptoPriceWarmer")
struct CryptoPriceWarmerTests {
  private let ethInstrument = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
  )
  private let ethMapping = CryptoProviderMapping(
    instrumentId: "1:native", coingeckoId: "ethereum",
    binanceSymbol: "ETHUSDT"
  )

  private func date(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    guard let result = formatter.date(from: string) else {
      fatalError("Could not parse ISO8601 full-date string: \(string)")
    }
    return result
  }

  private func cryptoTxn(account: UUID, instrument: Instrument, on date: Date) -> Transaction {
    Transaction(
      date: date, payee: "buy",
      legs: [TransactionLeg(accountId: account, instrument: instrument, quantity: 1, type: .trade)])
  }

  @Test("cooldown then success: warmer sleeps once, then fills")
  func cooldownThenSuccess() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    let toggle = ToggleableCryptoPriceClient()
    await toggle.setShouldFail(
      true, error: RateLimitGateError.cooldown(until: date("2026-06-07")))
    let service = CryptoPriceService(
      clients: [toggle], database: database, now: { self.date("2026-06-08") })

    let registration = CryptoRegistration(instrument: ethInstrument, mapping: ethMapping)
    let sleeps = SleepRecorder()
    let warmer = CryptoPriceWarmer(
      priceService: service,
      registrations: { [registration] },
      now: { self.date("2026-06-08") },
      sleep: { duration in
        sleeps.record(duration)
        // After the first cooldown sleep, the provider recovers.
        await toggle.setPrices(["1:native": ["2026-01-01": dec("100")]])
        await toggle.setShouldFail(false, error: nil)
      })

    let account = UUID()
    await warmer.warm(
      transactions: [
        cryptoTxn(account: account, instrument: ethInstrument, on: date("2026-01-01"))
      ],
      accountIds: [account])

    #expect(sleeps.count == 1)
    // Cache now serves the warmed price.
    let reader = CryptoPriceService(
      clients: [], database: database, now: { self.date("2026-06-08") })
    let price = try await reader.price(
      for: ethInstrument, mapping: ethMapping, on: date("2026-01-01"))
    #expect(price == dec("100"))
  }

  @Test("permanent failure: warmer gives up after maxCooldownCycles, never throws")
  func permanentCooldownGivesUp() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    let client = FixedCryptoPriceClient(
      prices: [:], shouldFail: true,
      failureError: RateLimitGateError.cooldown(until: date("2026-06-07")))
    let service = CryptoPriceService(
      clients: [client], database: database, now: { self.date("2026-06-08") })
    let sleeps = SleepRecorder()
    let warmer = CryptoPriceWarmer(
      priceService: service,
      registrations: {
        [CryptoRegistration(instrument: self.ethInstrument, mapping: self.ethMapping)]
      },
      now: { self.date("2026-06-08") },
      sleep: { sleeps.record($0) },
      maxCooldownCycles: 3)
    let account = UUID()
    await warmer.warm(
      transactions: [
        cryptoTxn(account: account, instrument: ethInstrument, on: date("2026-01-01"))
      ],
      accountIds: [account])
    // Cooldown is retried after a sleep up to maxCooldownCycles times, then
    // the gap is left for the next sync — three deadlines waited out.
    #expect(sleeps.count == 3)
  }

  @Test("unpriced registrations are skipped")
  func unpricedSkipped() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    let counting = CountingCryptoPriceClient(FixedCryptoPriceClient(prices: [:]))
    let service = CryptoPriceService(
      clients: [counting], database: database, now: { self.date("2026-06-08") })
    let warmer = CryptoPriceWarmer(
      priceService: service,
      registrations: {
        [
          CryptoRegistration(
            instrument: self.ethInstrument, mapping: self.ethMapping, pricingStatus: .spam)
        ]
      },
      now: { self.date("2026-06-08") },
      sleep: { _ in })
    let account = UUID()
    await warmer.warm(
      transactions: [
        cryptoTxn(account: account, instrument: ethInstrument, on: date("2026-01-01"))
      ],
      accountIds: [account])
    #expect(counting.fetchCount == 0)
  }
}
