// MoolahTests/Support/ExchangeSyncEngineTestSupport.swift
import Foundation

@testable import Moolah

/// Builds a `ExchangeSyncEngine` wired against the provided registry and an
/// optional `CountingRegistrationResolver`. When `regResolver` is `nil` a
/// default resolver scripted with a `.success` response is created
/// automatically. The Alchemy stub and discovery service are created fresh
/// each call so tests that need to inspect them should pass an explicit
/// `regResolver` or construct the engine manually.
///
/// `existingLegInstrumentIds` always returns `[]` — suitable for resolution
/// tests that do not need to exercise the used-instrument preference ranking.
///
/// `importOriginFactory` defaults to a fixed test origin so resolution /
/// grouping tests that only care about `legs` and `date` need not think
/// about it; tests that assert ImportOrigin propagation pass an explicit
/// pinned factory.
func makeExchangeSyncEngine(
  registry: StubInstrumentRegistry = StubInstrumentRegistry(),
  regResolver: CountingRegistrationResolver? = nil,
  importOriginFactory: @Sendable @escaping (UUID) -> ImportOrigin = { accountId in
    ImportOrigin(
      rawDescription: "exchange:\(accountId.uuidString)",
      rawAmount: 0,
      importedAt: Date(timeIntervalSince1970: 0),
      importSessionId: UUID(),
      parserIdentifier: "coinstash")
  }
) -> ExchangeSyncEngine {
  let resolverToUse: CountingRegistrationResolver
  if let regResolver {
    resolverToUse = regResolver
  } else {
    let defaultResolver = CountingRegistrationResolver()
    defaultResolver.setDefault(.success(coingecko: "id", cryptocompare: nil, binance: nil))
    resolverToUse = defaultResolver
  }
  let discovery = CryptoTokenDiscoveryService(
    registry: registry, resolver: resolverToUse, alchemy: CountingAlchemyClientStub())
  return ExchangeSyncEngine(
    resolver: ExchangeInstrumentResolver(
      registry: registry, fiatInstrument: .AUD,
      existingLegInstrumentIds: { [] }),
    discovery: discovery,
    importOriginFactory: importOriginFactory)
}
