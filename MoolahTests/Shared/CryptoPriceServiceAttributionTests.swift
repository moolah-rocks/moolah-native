// MoolahTests/Shared/CryptoPriceServiceAttributionTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Pins last-provider attribution for the two `CryptoPriceService`
/// exhausting fallback loops (`price(for:mapping:on:)` and
/// `prices(for:mapping:in:)`'s `fetchRange`). When *all* price clients
/// fail, the thrown error must be a `WalletSyncError` attributed to the
/// LAST provider attempted — production order is
/// CoinGecko → CryptoCompare → Binance, so `.binance` is last.
@Suite("CryptoPriceService last-provider attribution")
struct CryptoPriceServiceAttributionTests {
  private let ethInstrument = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
  )
  private let ethMapping = CryptoProviderMapping(
    instrumentId: "1:native", coingeckoId: "ethereum",
    cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"
  )

  private func date(_ string: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return try #require(formatter.date(from: string))
  }

  /// All clients throw; ordered so the last is `.binance`, matching the
  /// production fallback chain (CoinGecko → CryptoCompare → Binance).
  private func makeFailingService(now: @Sendable @escaping () -> Date) throws -> CryptoPriceService
  {
    let database = try ProfileIndexDatabase.openInMemory()
    let clients: [CryptoPriceClient] = [
      FixedCryptoPriceClient(shouldFail: true, syncProvider: .coinGecko),
      FixedCryptoPriceClient(shouldFail: true, syncProvider: .cryptoCompare),
      FixedCryptoPriceClient(shouldFail: true, syncProvider: .binance),
    ]
    return CryptoPriceService(
      clients: clients, database: database, resolutionClient: nil, now: now)
  }

  @Test("price(...) all-providers-fail throws WalletSyncError attributed to last provider")
  func singlePriceAttributesLastProvider() async throws {
    let frozen = try date("2024-02-01")
    let svc = try makeFailingService(now: { frozen })
    do {
      _ = try await svc.price(
        for: ethInstrument, mapping: ethMapping, on: try date("2024-01-15"))
      Issue.record("Expected a thrown error, got a value")
    } catch let error as WalletSyncError {
      #expect(error.provider == .binance)
    } catch {
      Issue.record("Expected WalletSyncError, got \(error)")
    }
  }

  @Test("prices(in:) all-providers-fail throws WalletSyncError attributed to last provider")
  func rangePricesAttributesLastProvider() async throws {
    let frozen = try date("2024-02-01")
    let svc = try makeFailingService(now: { frozen })
    do {
      _ = try await svc.prices(
        for: ethInstrument, mapping: ethMapping,
        in: try date("2024-01-10")...(try date("2024-01-20")))
      Issue.record("Expected a thrown error, got a value")
    } catch let error as WalletSyncError {
      #expect(error.provider == .binance)
    } catch {
      Issue.record("Expected WalletSyncError, got \(error)")
    }
  }

  /// `noProviderMapping` is a routing decision (the client has no
  /// symbol for the token), not a runtime failure — USDT, for instance,
  /// has no USDT/USDT pair on Binance, so the Binance leg ALWAYS throws
  /// `noProviderMapping` even when the network is healthy. Attribution
  /// must fall to a real failure (here, CoinGecko's network error), not
  /// to the trailing `noProviderMapping`-only leg.
  @Test("noProviderMapping is not surfaced as a provider failure for price(...)")
  func singlePriceSkipsNoProviderMappingAttribution() async throws {
    let frozen = try date("2024-02-01")
    let database = try ProfileIndexDatabase.openInMemory()
    let noMapping: any Error = CryptoPriceError.noProviderMapping(
      tokenId: ethMapping.instrumentId, provider: "Binance")
    let clients: [CryptoPriceClient] = [
      FixedCryptoPriceClient(shouldFail: true, syncProvider: .coinGecko),
      FixedCryptoPriceClient(
        shouldFail: true, failureError: noMapping, syncProvider: .cryptoCompare),
      FixedCryptoPriceClient(
        shouldFail: true, failureError: noMapping, syncProvider: .binance),
    ]
    let svc = CryptoPriceService(
      clients: clients, database: database, resolutionClient: nil, now: { frozen })
    do {
      _ = try await svc.price(
        for: ethInstrument, mapping: ethMapping, on: try date("2024-01-15"))
      Issue.record("Expected a thrown error, got a value")
    } catch let error as WalletSyncError {
      #expect(error.provider == .coinGecko)
      if case .network(let underlying) = error.kind {
        #expect(!underlying.contains("noProviderMapping"))
      }
    } catch {
      Issue.record("Expected WalletSyncError, got \(error)")
    }
  }

  @Test("noProviderMapping is not surfaced as a provider failure for prices(in:)")
  func rangePricesSkipsNoProviderMappingAttribution() async throws {
    let frozen = try date("2024-02-01")
    let database = try ProfileIndexDatabase.openInMemory()
    let noMapping: any Error = CryptoPriceError.noProviderMapping(
      tokenId: ethMapping.instrumentId, provider: "Binance")
    let clients: [CryptoPriceClient] = [
      FixedCryptoPriceClient(shouldFail: true, syncProvider: .coinGecko),
      FixedCryptoPriceClient(
        shouldFail: true, failureError: noMapping, syncProvider: .cryptoCompare),
      FixedCryptoPriceClient(
        shouldFail: true, failureError: noMapping, syncProvider: .binance),
    ]
    let svc = CryptoPriceService(
      clients: clients, database: database, resolutionClient: nil, now: { frozen })
    do {
      _ = try await svc.prices(
        for: ethInstrument, mapping: ethMapping,
        in: try date("2024-01-10")...(try date("2024-01-20")))
      Issue.record("Expected a thrown error, got a value")
    } catch let error as WalletSyncError {
      #expect(error.provider == .coinGecko)
      if case .network(let underlying) = error.kind {
        #expect(!underlying.contains("noProviderMapping"))
      }
    } catch {
      Issue.record("Expected WalletSyncError, got \(error)")
    }
  }
}
