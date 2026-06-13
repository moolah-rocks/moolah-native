// MoolahTests/Shared/CryptoImport/CryptoTokenDiscoveryTestDoubles.swift
import Foundation

@testable import Moolah

/// Namespace matching this file's name so SwiftLint's `file_name` rule
/// stays satisfied alongside the loose top-level helpers and the two
/// counting stubs declared below. Mirrors the `AlchemyTestSupport`
/// pattern in the sibling Alchemy test files.
enum CryptoTokenDiscoveryTestDoubles {}

/// Counting + scriptable resolver. Records every call and returns the
/// scripted response for the matching key. The default response is a
/// successful resolution producing a mapping with one provider id.
///
/// `@unchecked Sendable`: scripted responses and call counts live behind
/// an `NSLock`, mirroring the lock-protected stubs in `AlchemyTestSupport`
/// and the `RateLimiterTests` test clock. The lock-bracket pattern is
/// the project convention for non-actor concurrent test stubs.
final class CountingRegistrationResolver: CryptoRegistrationResolver, @unchecked Sendable {
  enum Response: Sendable {
    case success(coingecko: String?, cryptocompare: String?, binance: String?)
    case failure(any Error)
  }

  struct Key: Hashable, Sendable {
    let chainId: Int
    let contractAddress: String?
  }

  private let lock = NSLock()
  private var responses: [Key: Response] = [:]
  private var callCounts: [Key: Int] = [:]
  private var defaultResponse: Response = .success(
    coingecko: "default-id", cryptocompare: nil, binance: nil)

  func setDefault(_ response: Response) {
    lock.withLock { self.defaultResponse = response }
  }

  func script(_ key: Key, _ response: Response) {
    lock.withLock { responses[key] = response }
  }

  func callCount(for key: Key) -> Int {
    lock.withLock { callCounts[key] ?? 0 }
  }

  func resolveRegistration(
    chainId: Int,
    contractAddress: String?,
    symbol: String?,
    isNative: Bool
  ) async throws -> CryptoRegistration {
    let key = Key(chainId: chainId, contractAddress: contractAddress?.lowercased())
    let response: Response = lock.withLock {
      callCounts[key, default: 0] += 1
      return responses[key] ?? defaultResponse
    }

    switch response {
    case let .failure(error):
      throw error
    case let .success(coingecko, cryptocompare, binance):
      let resolvedSymbol = symbol ?? "TKN"
      let instrument = Instrument.crypto(
        chainId: chainId,
        contractAddress: isNative ? nil : contractAddress,
        symbol: resolvedSymbol,
        name: resolvedSymbol,
        decimals: 18)
      let mapping = CryptoProviderMapping(
        instrumentId: instrument.id,
        coingeckoId: coingecko,
        cryptocompareSymbol: cryptocompare,
        binanceSymbol: binance)
      return CryptoRegistration(instrument: instrument, mapping: mapping)
    }
  }
}

/// Bundle returned by `makeDiscoverySubject()` — a struct rather than a
/// tuple so SwiftLint's `large_tuple` rule (max 2 members) stays clean
/// and call sites can address fields by name.
struct CryptoTokenDiscoverySubject: Sendable {
  let service: CryptoTokenDiscoveryService
  let registry: StubInstrumentRegistry
  let resolver: CountingRegistrationResolver
}

/// Builds a `CryptoTokenDiscoveryService` wired against the in-memory
/// `StubInstrumentRegistry` plus the counting resolver. Tests script
/// resolver responses on the returned bundle's fields.
func makeDiscoverySubject(
  seededRegistrations: [CryptoRegistration] = []
) -> CryptoTokenDiscoverySubject {
  let registry = StubInstrumentRegistry(cryptoRegistrations: seededRegistrations)
  let resolver = CountingRegistrationResolver()
  let service = CryptoTokenDiscoveryService(
    registry: registry, resolver: resolver)
  return CryptoTokenDiscoverySubject(
    service: service, registry: registry, resolver: resolver)
}
