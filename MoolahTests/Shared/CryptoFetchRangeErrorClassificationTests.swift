import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("CryptoFetchRangeErrorClassification")
struct CryptoFetchRangeErrorClassificationTests {
  private let ethInstrument = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
  )
  private let ethMapping = CryptoProviderMapping(
    instrumentId: "1:native", coingeckoId: "ethereum",
    cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"
  )

  private func makeService(clients: [any CryptoPriceClient]) throws -> CryptoPriceService {
    let database = try ProfileIndexDatabase.openInMemory()
    return CryptoPriceService(
      clients: clients,
      database: database,
      resolutionClient: nil,
      now: { Date() }
    )
  }

  private func date(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    guard let result = formatter.date(from: string) else {
      fatalError("Could not parse ISO8601 full-date string: \(string)")
    }
    return result
  }

  @Test("a missing-API-key-only window does not throw (structural skip)")
  func missingKeyIsStructural() async throws {
    let client = FixedCryptoPriceClient(
      prices: [:],
      shouldFail: true,
      failureError: WalletSyncError.missingApiKey,
      syncProvider: .coinGecko
    )
    let service = try makeService(clients: [client])

    // A missing-API-key error is structural — fetchRange must NOT throw at all.
    // The provider is skipped (like noProviderMapping); no transient outage reported.
    try await service.fetchRange(
      instrument: ethInstrument,
      mapping: ethMapping,
      from: date("2024-01-01"),
      to: date("2024-01-07")
    )
  }

  @Test("an invalid-API-key-only window does not throw (structural skip)")
  func invalidKeyIsStructural() async throws {
    let client = FixedCryptoPriceClient(
      prices: [:],
      shouldFail: true,
      failureError: WalletSyncError.invalidApiKey,
      syncProvider: .coinGecko
    )
    let service = try makeService(clients: [client])

    // An invalid-API-key error is structural — fetchRange must NOT throw at all.
    try await service.fetchRange(
      instrument: ethInstrument,
      mapping: ethMapping,
      from: date("2024-01-01"),
      to: date("2024-01-07")
    )
  }

  @Test("a rate-limited window surfaces a transient failure")
  func rateLimitIsTransient() async throws {
    let client = FixedCryptoPriceClient(
      prices: [:],
      shouldFail: true,
      failureError: WalletSyncError.rateLimited(retryAfter: nil),
      syncProvider: .coinGecko
    )
    let service = try makeService(clients: [client])

    do {
      try await service.fetchRange(
        instrument: ethInstrument,
        mapping: ethMapping,
        from: date("2024-01-01"),
        to: date("2024-01-07")
      )
      Issue.record("Expected fetchRange to throw for a rate-limited error")
    } catch {
      #expect(
        ConversionFailureClassifier.isTransient(error),
        "rate-limit error must be classified as transient, got: \(error)"
      )
    }
  }

  @Test("a network error surfaces a transient failure")
  func networkErrorIsTransient() async throws {
    let networkError = URLError(.notConnectedToInternet)
    let client = FixedCryptoPriceClient(
      prices: [:],
      shouldFail: true,
      failureError: networkError,
      syncProvider: .coinGecko
    )
    let service = try makeService(clients: [client])

    do {
      try await service.fetchRange(
        instrument: ethInstrument,
        mapping: ethMapping,
        from: date("2024-01-01"),
        to: date("2024-01-07")
      )
      Issue.record("Expected fetchRange to throw for a network error")
    } catch {
      #expect(
        ConversionFailureClassifier.isTransient(error),
        "network error must be classified as transient, got: \(error)"
      )
    }
  }

  @Test("a malformed-response-only window surfaces a transient failure (not structural skip)")
  func malformedResponseIsOperational() async throws {
    let client = FixedCryptoPriceClient(
      prices: [:],
      shouldFail: true,
      failureError: WalletSyncError.providerMalformedResponse(stage: "parse"),
      syncProvider: .coinGecko
    )
    let service = try makeService(clients: [client])

    // A malformed response means the provider could have had data but glitched —
    // fetchRange MUST throw so a later task cannot conclude "no data" and value
    // the token at $0. With the bug (isTransient predicate) it silently returns.
    do {
      try await service.fetchRange(
        instrument: ethInstrument,
        mapping: ethMapping,
        from: date("2024-01-01"),
        to: date("2024-01-07")
      )
      Issue.record("Expected fetchRange to throw for a malformed-response error")
    } catch {
      #expect(
        ConversionFailureClassifier.isTransient(error),
        "malformed-response error must be classified as transient, got: \(error)"
      )
    }
  }

  @Test("structural failure followed by operational failure surfaces transient error")
  func structuralThenOperationalIsTransient() async throws {
    let missingKeyClient = FixedCryptoPriceClient(
      prices: [:],
      shouldFail: true,
      failureError: WalletSyncError.missingApiKey,
      syncProvider: .coinGecko
    )
    let networkClient = FixedCryptoPriceClient(
      prices: [:],
      shouldFail: true,
      failureError: URLError(.timedOut),
      syncProvider: .cryptoCompare
    )
    let service = try makeService(clients: [missingKeyClient, networkClient])

    do {
      try await service.fetchRange(
        instrument: ethInstrument,
        mapping: ethMapping,
        from: date("2024-01-01"),
        to: date("2024-01-07")
      )
      Issue.record("Expected fetchRange to throw when an operational error occurred")
    } catch {
      #expect(
        ConversionFailureClassifier.isTransient(error),
        "structural + operational should surface transient, got: \(error)"
      )
    }
  }
}
