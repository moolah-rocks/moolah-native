import Foundation
import Testing

@testable import Moolah

@MainActor
@Suite("AccountStore preloads only recordedValue accounts")
struct AccountStorePreloadFilterTests {
  @Test("only recordedValue investment accounts get a preload")
  func preloadFiltersByMode() async throws {
    let (backend, _) = try TestBackend.create()
    let recorded = try await backend.accounts.create(
      Account(
        name: "R", type: .investment, instrument: .AUD,
        valuationMode: .recordedValue))
    let trades = try await backend.accounts.create(
      Account(
        name: "T", type: .investment, instrument: .AUD,
        valuationMode: .calculatedFromTrades))
    try await backend.investments.setValue(
      accountId: recorded.id, date: Date(timeIntervalSince1970: 1_700_000_000),
      value: InstrumentAmount(quantity: 100, instrument: .AUD))
    try await backend.investments.setValue(
      accountId: trades.id, date: Date(timeIntervalSince1970: 1_700_000_000),
      value: InstrumentAmount(quantity: 999, instrument: .AUD))

    let store = AccountStore(
      repository: backend.accounts,
      conversionService: FixedConversionService(),
      targetInstrument: .AUD,
      investmentRepository: backend.investments)
    await expectEventually("only recordedValue account is preloaded") {
      store.investmentValues[recorded.id] != nil && store.investmentValues[trades.id] == nil
    }
  }

  @Test("crypto accounts are never preloaded into the investment snapshot cache")
  func cryptoAccountNeverPreloaded() async throws {
    let (backend, _) = try TestBackend.create()
    let recorded = try await backend.accounts.create(
      Account(
        name: "R", type: .investment, instrument: .AUD,
        valuationMode: .recordedValue))
    // A crypto account is `.calculatedFromTrades` and denominated in the
    // profile currency; its worth comes from leg aggregation, never the
    // investment-value snapshot. A stray snapshot in the repo must not
    // leak into `investmentValues` for it.
    let wallet = try await backend.accounts.create(
      Account(
        name: "Hardware Wallet", type: .crypto, instrument: .AUD,
        valuationMode: .calculatedFromTrades,
        walletAddress: "0x" + String(repeating: "a", count: 40),
        chainId: 1))
    try await backend.investments.setValue(
      accountId: recorded.id, date: Date(timeIntervalSince1970: 1_700_000_000),
      value: InstrumentAmount(quantity: 100, instrument: .AUD))
    try await backend.investments.setValue(
      accountId: wallet.id, date: Date(timeIntervalSince1970: 1_700_000_000),
      value: InstrumentAmount(quantity: 777, instrument: .AUD))

    let store = AccountStore(
      repository: backend.accounts,
      conversionService: FixedConversionService(),
      targetInstrument: .AUD,
      investmentRepository: backend.investments)
    await expectEventually("recorded account preloads but crypto wallet does not") {
      store.investmentValues[recorded.id] != nil && store.investmentValues[wallet.id] == nil
    }
  }

  @Test("flipping mode to recordedValue triggers a snapshot preload")
  func updateToRecordedValuePreloadsSnapshot() async throws {
    let (backend, _) = try TestBackend.create()
    let account = try await backend.accounts.create(
      Account(
        name: "Brokerage", type: .investment, instrument: .AUD,
        valuationMode: .calculatedFromTrades))
    try await backend.investments.setValue(
      accountId: account.id, date: Date(timeIntervalSince1970: 1_700_000_000),
      value: InstrumentAmount(quantity: 250, instrument: .AUD))

    let store = AccountStore(
      repository: backend.accounts,
      conversionService: FixedConversionService(),
      targetInstrument: .AUD,
      investmentRepository: backend.investments)
    try await store.waitForNextEmission(
      matching: { $0.accounts.by(id: account.id) != nil },
      description: "seeded account observed"
    )

    // The snapshot exists in the repo but the cache excluded it because
    // the account was in `calculatedFromTrades` mode at load time.
    #expect(store.investmentValues[account.id] == nil)

    var updated = account
    updated.valuationMode = .recordedValue
    _ = try await store.update(updated)

    // Wait for the observation to deliver the updated mode and trigger
    // the snapshot preload.
    await expectEventually("snapshot preloads after mode flip to recordedValue") {
      store.investmentValues[account.id]?.quantity == 250
    }
  }
}
