// MoolahTests/Support/StubInstrumentRegistry.swift
import Foundation
import os

@testable import Moolah

/// In-memory stub of `InstrumentRegistryRepository` for store/service unit
/// tests that don't need a real `CloudKitInstrumentRegistryRepository`. Records
/// every `registerStock` / `registerCrypto` / `remove` call so tests can
/// assert on the side effects.
///
/// Sendable via `OSAllocatedUnfairLock`-guarded storage so it's safe to call
/// async-throwing methods from Swift 6 strict-concurrency contexts.
final class StubInstrumentRegistry: InstrumentRegistryRepository, Sendable {
  struct State: Sendable {
    var instruments: [Instrument]
    var cryptoRegistrations: [CryptoRegistration]
    var registeredStocks: [Instrument]
    var registeredCryptos: [CryptoRegistration]
    var removedIds: [String]
    var shouldThrowOnRegister: Bool
    /// Number of `update(_:)` calls. Lets tests assert that a flow
    /// reached the registry in a single write (e.g. #895's
    /// `performResolution` routing through `registerCrypto(forcingStatus:)`
    /// instead of `registerCrypto` + `update`).
    var updateCallCount: Int = 0
  }

  /// Errors thrown by the stub when `shouldThrowOnRegister` is set. Lets
  /// tests exercise the picker's "registry write failed after a successful
  /// resolve" path without needing a separate stub class.
  enum RegisterError: Error { case stockFailed, cryptoFailed, updateFailed }

  private let state: OSAllocatedUnfairLock<State>

  init(
    instruments: [Instrument] = [],
    cryptoRegistrations: [CryptoRegistration] = [],
    shouldThrowOnRegister: Bool = false
  ) {
    self.state = OSAllocatedUnfairLock(
      initialState: State(
        instruments: instruments,
        cryptoRegistrations: cryptoRegistrations,
        registeredStocks: [],
        registeredCryptos: [],
        removedIds: [],
        shouldThrowOnRegister: shouldThrowOnRegister
      )
    )
  }

  // MARK: - Inspection

  /// Snapshots the current state for assertions in tests. Threadsafe.
  func snapshot() -> State {
    state.withLock { $0 }
  }
}

extension StubInstrumentRegistry {
  func all() async throws -> [Instrument] {
    state.withLock { $0.instruments }
  }

  func allCryptoRegistrations() async throws -> [CryptoRegistration] {
    state.withLock { $0.cryptoRegistrations }
  }

  func cryptoRegistration(byId id: String) async throws -> CryptoRegistration? {
    state.withLock { state in
      state.cryptoRegistrations.first { $0.id == id }
    }
  }

  func registerCrypto(
    _ instrument: Instrument, mapping: CryptoProviderMapping
  ) async throws {
    try state.withLock { state in
      if state.shouldThrowOnRegister { throw RegisterError.cryptoFailed }
      let registration = CryptoRegistration(instrument: instrument, mapping: mapping)
      state.registeredCryptos.append(registration)
      state.cryptoRegistrations.removeAll { $0.id == registration.id }
      state.cryptoRegistrations.append(registration)
      state.instruments.removeAll { $0.id == instrument.id }
      state.instruments.append(instrument)
    }
  }

  func registerCrypto(
    _ instrument: Instrument,
    mapping: CryptoProviderMapping,
    forcingStatus status: TokenPricingStatus
  ) async throws {
    try state.withLock { state in
      if state.shouldThrowOnRegister { throw RegisterError.cryptoFailed }
      let registration = CryptoRegistration(
        instrument: instrument, mapping: mapping, pricingStatus: status)
      state.registeredCryptos.append(registration)
      state.cryptoRegistrations.removeAll { $0.id == registration.id }
      state.cryptoRegistrations.append(registration)
      state.instruments.removeAll { $0.id == instrument.id }
      state.instruments.append(instrument)
    }
  }

  func registerStock(_ instrument: Instrument) async throws {
    try state.withLock { state in
      if state.shouldThrowOnRegister { throw RegisterError.stockFailed }
      state.registeredStocks.append(instrument)
      state.instruments.removeAll { $0.id == instrument.id }
      state.instruments.append(instrument)
    }
  }

  func update(_ registration: CryptoRegistration) async throws {
    try state.withLock { state in
      if state.shouldThrowOnRegister { throw RegisterError.updateFailed }
      state.updateCallCount += 1
      guard
        let index = state.cryptoRegistrations.firstIndex(where: { $0.id == registration.id })
      else { return }
      state.cryptoRegistrations[index] = registration
    }
  }

  func remove(id: String) async throws {
    state.withLock { state in
      state.removedIds.append(id)
      state.instruments.removeAll { $0.id == id }
      state.cryptoRegistrations.removeAll { $0.id == id }
    }
  }

  /// Immediately-finishing stream = "never notifies". The consuming
  /// observation task ends naturally on the finish instead of hanging
  /// until `stopObserving()` cancels it (a never-finishing `{ _ in }`
  /// stream would leave the task parked indefinitely — a test footgun).
  @MainActor
  func observeChanges() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}
