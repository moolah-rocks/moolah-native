import Foundation
import Testing
import os

@testable import Moolah

@Suite("InstrumentPickerStore.select crypto branches")
@MainActor
struct InstrumentPickerStoreCryptoSelectTests {
  @Test("selecting unregistered crypto resolves and registers via the resolver")
  func selectUnregisteredCryptoRunsResolveAndRegisters() async throws {
    let registry = StubInstrumentRegistry()
    let resolver = RecordingTokenResolutionClient(
      result: TokenResolutionResult(
        coingeckoId: "uniswap",
        binanceSymbol: "UNIUSDT",
        resolvedName: "Uniswap",
        resolvedSymbol: "UNI",
        resolvedDecimals: 18
      )
    )
    let result = InstrumentSearchResult(
      instrument: Instrument.crypto(
        chainId: 1, contractAddress: "0xuni", symbol: "UNI", name: "Uniswap", decimals: 18
      ),
      cryptoMapping: nil,
      isRegistered: false,
      requiresResolution: true
    )
    let store = InstrumentPickerStore(
      registry: registry,
      resolutionClient: resolver,
      kinds: [.cryptoToken]
    )

    let selected = await store.select(result)

    #expect(selected != nil)
    #expect(selected?.id == "1:0xuni")
    let snapshot = registry.snapshot()
    #expect(snapshot.registeredCryptos.count == 1)
    #expect(snapshot.registeredCryptos.first?.mapping.coingeckoId == "uniswap")
    #expect(snapshot.registeredCryptos.first?.mapping.binanceSymbol == "UNIUSDT")
    #expect(store.error == nil)
    #expect(store.isResolving == false)
    let resolverCalls = resolver.calls
    #expect(resolverCalls.count == 1)
    #expect(resolverCalls.first?.chainId == 1)
    #expect(resolverCalls.first?.contractAddress == "0xuni")
    #expect(resolverCalls.first?.isNative == false)
  }

  @Test("selecting unregistered native crypto resolves with isNative=true and nil contract")
  func selectUnregisteredNativeCryptoUsesIsNativeTrue() async throws {
    let registry = StubInstrumentRegistry()
    let resolver = RecordingTokenResolutionClient(
      result: TokenResolutionResult(
        coingeckoId: "bitcoin",
        binanceSymbol: "BTCUSDT",
        resolvedName: "Bitcoin",
        resolvedSymbol: "BTC",
        resolvedDecimals: 8
      )
    )
    let result = InstrumentSearchResult(
      instrument: Instrument.crypto(
        chainId: 0, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8
      ),
      cryptoMapping: nil,
      isRegistered: false,
      requiresResolution: true
    )
    let store = InstrumentPickerStore(
      registry: registry,
      resolutionClient: resolver,
      kinds: [.cryptoToken]
    )

    let selected = await store.select(result)

    #expect(selected?.id == "0:native")
    let resolverCalls = resolver.calls
    #expect(resolverCalls.count == 1)
    #expect(resolverCalls.first?.isNative == true)
    #expect(resolverCalls.first?.contractAddress == nil)
    let snapshot = registry.snapshot()
    #expect(snapshot.registeredCryptos.count == 1)
  }

  @Test("selecting unregistered crypto with no provider mapping fails and writes nothing")
  func selectUnregisteredCryptoWithoutAnyMappingFailsAndDoesNotWrite() async throws {
    let registry = StubInstrumentRegistry()
    let resolver = RecordingTokenResolutionClient(
      result: TokenResolutionResult()
    )
    let result = InstrumentSearchResult(
      instrument: Instrument.crypto(
        chainId: 1, contractAddress: "0xfoo", symbol: "FOO", name: "Foo", decimals: 18
      ),
      cryptoMapping: nil,
      isRegistered: false,
      requiresResolution: true
    )
    let store = InstrumentPickerStore(
      registry: registry,
      resolutionClient: resolver,
      kinds: [.cryptoToken]
    )

    let selected = await store.select(result)

    #expect(selected == nil)
    #expect(store.error != nil)
    #expect(store.isResolving == false)
    let snapshot = registry.snapshot()
    #expect(snapshot.registeredCryptos.isEmpty)
  }

  @Test("selecting registered crypto returns immediately without resolving")
  func selectRegisteredCryptoReturnsImmediately() async throws {
    let registered = Instrument.crypto(
      chainId: 1, contractAddress: "0xuni", symbol: "UNI", name: "Uniswap", decimals: 18
    )
    let mapping = CryptoProviderMapping(
      instrumentId: registered.id,
      coingeckoId: "uniswap",
      binanceSymbol: nil
    )
    let registry = StubInstrumentRegistry(
      instruments: [registered],
      cryptoRegistrations: [CryptoRegistration(instrument: registered, mapping: mapping)]
    )
    let resolver = RecordingTokenResolutionClient(result: TokenResolutionResult())
    let result = InstrumentSearchResult(
      instrument: registered,
      cryptoMapping: mapping,
      isRegistered: true,
      requiresResolution: false
    )
    let store = InstrumentPickerStore(
      registry: registry,
      resolutionClient: resolver,
      kinds: [.cryptoToken]
    )

    let selected = await store.select(result)

    #expect(selected?.id == registered.id)
    #expect(resolver.calls.isEmpty)
    let snapshot = registry.snapshot()
    #expect(snapshot.registeredCryptos.isEmpty)
  }

  @Test("selecting unregistered crypto surfaces resolver errors")
  func selectUnregisteredCryptoSurfacesResolverError() async throws {
    let registry = StubInstrumentRegistry()
    let resolver = RecordingTokenResolutionClient(
      result: TokenResolutionResult(),
      shouldFail: true
    )
    let result = InstrumentSearchResult(
      instrument: Instrument.crypto(
        chainId: 1, contractAddress: "0xbar", symbol: "BAR", name: "Bar", decimals: 18
      ),
      cryptoMapping: nil,
      isRegistered: false,
      requiresResolution: true
    )
    let store = InstrumentPickerStore(
      registry: registry,
      resolutionClient: resolver,
      kinds: [.cryptoToken]
    )

    let selected = await store.select(result)

    #expect(selected == nil)
    #expect(store.error != nil)
    let snapshot = registry.snapshot()
    #expect(snapshot.registeredCryptos.isEmpty)
  }

  @Test("selecting unregistered crypto surfaces registry-write errors after resolve succeeds")
  func selectUnregisteredCryptoSurfacesRegistryError() async throws {
    let registry = StubInstrumentRegistry(shouldThrowOnRegister: true)
    let resolver = RecordingTokenResolutionClient(
      result: TokenResolutionResult(
        coingeckoId: "uniswap",
        binanceSymbol: nil,
        resolvedName: nil,
        resolvedSymbol: nil,
        resolvedDecimals: nil
      )
    )
    let result = InstrumentSearchResult(
      instrument: Instrument.crypto(
        chainId: 1, contractAddress: "0xuni", symbol: "UNI", name: "Uniswap", decimals: 18
      ),
      cryptoMapping: nil,
      isRegistered: false,
      requiresResolution: true
    )
    let store = InstrumentPickerStore(
      registry: registry,
      resolutionClient: resolver,
      kinds: [.cryptoToken]
    )

    let selected = await store.select(result)

    #expect(selected == nil)
    #expect(store.error != nil)
    #expect(store.isResolving == false)
    // Resolver was called (resolve succeeded); registry-write throw is what surfaced.
    #expect(resolver.calls.count == 1)
    let snapshot = registry.snapshot()
    #expect(snapshot.registeredCryptos.isEmpty)
  }
}

/// Test resolver that records each `resolve` call so tests can assert on
/// chainId / contractAddress / isNative — all three matter for the picker's
/// branch logic in Task 9.
private final class RecordingTokenResolutionClient: TokenResolutionClient, Sendable {
  struct Call: Sendable {
    let chainId: Int
    let contractAddress: String?
    let symbol: String?
    let isNative: Bool
  }

  private let recordedCalls: OSAllocatedUnfairLock<[Call]> = .init(initialState: [])
  private let result: TokenResolutionResult
  private let shouldFail: Bool

  init(result: TokenResolutionResult, shouldFail: Bool = false) {
    self.result = result
    self.shouldFail = shouldFail
  }

  var calls: [Call] { recordedCalls.withLock { $0 } }

  func resolve(
    chainId: Int, contractAddress: String?, symbol: String?, isNative: Bool
  ) async throws -> TokenResolutionResult {
    recordedCalls.withLock { calls in
      calls.append(
        Call(
          chainId: chainId,
          contractAddress: contractAddress,
          symbol: symbol,
          isNative: isNative
        )
      )
    }
    if shouldFail { throw URLError(.notConnectedToInternet) }
    return result
  }
}
