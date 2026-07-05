// MoolahTests/Shared/CryptoImport/CanonicalInstrumentResolverTestSupport.swift
// Shared test helpers for CanonicalInstrumentResolver tests.
//
// Case-less enum used as a namespace per `guides/CODE_GUIDE.md` §5 (also
// satisfies SwiftLint's file_name rule requiring the filename to match a
// declared type).
//
// The free helpers (`reg`, `pollUntil`, `pollUntilOrFalse`, `PollTimeout`)
// and the stub classes live at file scope so the split test files can call
// them without a namespace prefix — identical to how the original private
// helpers were used before the file split.

import Foundation
import Testing
import os

@testable import Moolah

// MARK: - Namespace marker (file_name rule)

/// Namespace enum for shared CanonicalInstrumentResolver test fixtures.
enum CanonicalInstrumentResolverTestSupport {}

// MARK: - reg() factory

/// Builds a `CryptoRegistration` whose `instrument.id` matches `id` exactly.
/// Extracts the contract address from the `id` suffix (everything after `:`)
/// unless the suffix is `"native"`, in which case `contractAddress` is nil.
func reg(
  _ id: String, chainId: Int, coingeckoId: String?
) -> CryptoRegistration {
  let address: String? =
    id.hasSuffix(":native")
    ? nil : String(id.split(separator: ":", maxSplits: 1)[1])
  return CryptoRegistration(
    instrument: .crypto(
      chainId: chainId, contractAddress: address, symbol: "X", name: "X", decimals: 18),
    mapping: CryptoProviderMapping(
      instrumentId: id, coingeckoId: coingeckoId,
      binanceSymbol: nil))
}

// MARK: - ThrowingCryptoRegistryStub

/// A minimal `InstrumentRegistryRepository` stub whose `allCryptoRegistrations()`
/// always throws. Used to exercise the `refresh(from:)` error-swallow path.
final class ThrowingCryptoRegistryStub: InstrumentRegistryRepository, @unchecked Sendable {
  enum Failure: Error { case intentional }

  func all() async throws -> [Instrument] { [] }
  func allCryptoRegistrations() async throws -> [CryptoRegistration] {
    throw Failure.intentional
  }
  func allCryptoRegistrationsIncludingAliased() async throws -> [CryptoRegistration] {
    throw Failure.intentional
  }
  func cryptoRegistration(byId id: String) async throws -> CryptoRegistration? { nil }
  func registerCrypto(_ instrument: Instrument, mapping: CryptoProviderMapping) async throws {}
  func registerCrypto(
    _ instrument: Instrument,
    mapping: CryptoProviderMapping,
    forcingStatus status: TokenPricingStatus
  ) async throws {}
  func registerStock(_ instrument: Instrument) async throws {}
  func update(_ registration: CryptoRegistration) async throws {}
  func remove(id: String) async throws {}
  @MainActor
  func observeChanges() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

// MARK: - CountingRegistryStub

/// A minimal `InstrumentRegistryRepository` stub that counts calls to
/// `allCryptoRegistrations()`. Used to assert no additional refresh fires
/// after the observation task is cancelled.
final class CountingRegistryStub: InstrumentRegistryRepository, Sendable {
  private let _callCount = OSAllocatedUnfairLock(initialState: 0)
  private let _registrations: [CryptoRegistration]

  var callCount: Int { _callCount.withLock { $0 } }

  init(registrations: [CryptoRegistration]) {
    _registrations = registrations
  }

  func all() async throws -> [Instrument] { [] }
  func allCryptoRegistrations() async throws -> [CryptoRegistration] {
    _callCount.withLock { $0 += 1 }
    return _registrations
  }
  func allCryptoRegistrationsIncludingAliased() async throws -> [CryptoRegistration] {
    _callCount.withLock { $0 += 1 }
    return _registrations
  }
  func cryptoRegistration(byId id: String) async throws -> CryptoRegistration? { nil }
  func registerCrypto(_ instrument: Instrument, mapping: CryptoProviderMapping) async throws {}
  func registerCrypto(
    _ instrument: Instrument,
    mapping: CryptoProviderMapping,
    forcingStatus status: TokenPricingStatus
  ) async throws {}
  func registerStock(_ instrument: Instrument) async throws {}
  func update(_ registration: CryptoRegistration) async throws {}
  func remove(id: String) async throws {}
  @MainActor
  func observeChanges() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

// MARK: - Poll helpers

/// Polls `condition` in a tight loop until it returns `true` or `timeout`
/// elapses. Throws `PollTimeout` on expiry. Matches the 10-second wait
/// convention (guides/AI_ASSISTANT_GUIDE.md — test wait timeouts).
func pollUntil(
  timeout: Duration = .seconds(10),
  _ condition: () -> Bool
) async throws {
  let deadline = ContinuousClock().now.advanced(by: timeout)
  while !condition() {
    if ContinuousClock().now >= deadline {
      throw PollTimeout()
    }
    try await Task.sleep(for: .milliseconds(10))
    if Task.isCancelled { return }
  }
}

/// Polls `condition` in a tight loop for up to `timeout`, returning `true`
/// if the condition becomes true and `false` if the timeout elapses first.
/// Used for absence assertions (confirming something does NOT happen).
func pollUntilOrFalse(
  timeout: Duration,
  _ condition: () -> Bool
) async -> Bool {
  let deadline = ContinuousClock().now.advanced(by: timeout)
  while ContinuousClock().now < deadline {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return false
}

struct PollTimeout: Error, CustomStringConvertible {
  var description: String { "pollUntil timed out waiting for condition" }
}
