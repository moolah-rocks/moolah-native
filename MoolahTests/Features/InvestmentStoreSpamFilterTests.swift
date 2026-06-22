import Foundation
import Testing

@testable import Moolah

/// Issue #790 — `.unpriced` / `.spam` crypto positions must not appear
/// in the account's position list. Splits two scenarios that share the
/// same fixture shape:
///
/// 1. Initial load: a position whose conversion already resolves to
///    `.knownZero` is dropped from `valuedPositions` immediately.
/// 2. Mid-session flip: marking a registration `.spam` from the
///    Registered Tokens list fires `CryptoTokenStore.onRegistrationsChanged`,
///    which `ProfileSession` wires to
///    `InvestmentStore.revaluateLoadedPositions()`. The store
///    recomputes against the freshly-updated registry and the spam
///    position drops out without the user having to navigate away
///    and back.
@Suite("InvestmentStore — Spam / Unpriced Filter")
@MainActor
struct InvestmentStoreSpamFilterTests {

  private func date(daysFromEpoch days: Int) -> Date {
    Date(timeIntervalSince1970: TimeInterval(days * 86_400))
  }

  private let realOp = Instrument.crypto(
    chainId: 10,
    contractAddress: "0x4200000000000000000000000000000000000042",
    symbol: "OP", name: "Optimism", decimals: 18)
  private let spamOp = Instrument.crypto(
    chainId: 10,
    contractAddress: "0x7e087b1c173441f6c96b00231c1eab9e59f9a5a7",
    symbol: "OP", name: "Spam OP", decimals: 18)

  /// Sibling priced positions render normally and the portfolio total
  /// excludes the unpriced contribution (zero by design).
  @Test
  func valuatePositions_dropsKnownZeroSpamFromList() async throws {
    let accountId = UUID()
    let aud = Instrument.AUD

    let (backend, database) = try TestBackend.create()
    try await TestBackend.register(realOp, in: backend)
    try await TestBackend.register(spamOp, in: backend)
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "OP Wallet", type: .crypto, instrument: aud,
          valuationMode: .calculatedFromTrades)
      ], in: database)
    TestBackend.seed(
      transactions: [
        Transaction(
          date: date(daysFromEpoch: 19_900),
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: realOp,
              quantity: Decimal(100), type: .transfer)
          ]),
        Transaction(
          date: date(daysFromEpoch: 19_901),
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: spamOp,
              quantity: Decimal(1_000_000), type: .transfer)
          ]),
      ], in: database)

    let conversion = FakeConversionService.fixedRates(
      [realOp.id: Decimal(5)],
      knownZero: [spamOp.id])
    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: conversion)

    await store.loadPositions(accountId: accountId)
    #expect(store.positions.count == 2)  // Both legs land in `positions`.

    await store.valuatePositions(profileCurrency: aud, on: Date())

    // Only the priced position survives into `valuedPositions`.
    #expect(store.valuedPositions.count == 1)
    let surviving = try #require(store.valuedPositions.first)
    #expect(surviving.instrument == realOp)
    #expect(surviving.value?.quantity == Decimal(500))  // 100 * 5

    #expect(store.totalPortfolioValue == Decimal(500))
    #expect(store.error == nil)
  }

  @Test
  func revaluateLoadedPositions_dropsNewlySpamMarkedFromList() async throws {
    let accountId = UUID()
    let aud = Instrument.AUD

    let (backend, database) = try TestBackend.create()
    try await TestBackend.register(realOp, in: backend)
    try await TestBackend.register(spamOp, in: backend)
    let account = Account(
      id: accountId, name: "OP Wallet", type: .crypto, instrument: aud,
      valuationMode: .calculatedFromTrades)
    TestBackend.seed(accounts: [account], in: database)
    TestBackend.seed(
      transactions: [
        Transaction(
          date: date(daysFromEpoch: 19_900),
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: realOp,
              quantity: Decimal(100), type: .transfer)
          ]),
        Transaction(
          date: date(daysFromEpoch: 19_901),
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: spamOp,
              quantity: Decimal(1_000_000), type: .transfer)
          ]),
      ], in: database)

    // Mutable stub modelling the `setStatus(.spam)` flip — both tokens
    // start priced; the test flips spamOp to `.knownZero` mid-session.
    let conversion = MutableKnownZeroConversionService(
      rates: [realOp.id: Decimal(5), spamOp.id: Decimal(7)])
    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: conversion)

    await store.loadAllData(account: account, profileCurrency: aud)
    #expect(store.valuedPositions.count == 2)

    // ProfileSession's `onRegistrationsChanged` callback fires this
    // method when a `setStatus(.spam)` lands in the registry.
    await conversion.markKnownZero(spamOp.id)
    await store.revaluateLoadedPositions()

    #expect(store.valuedPositions.count == 1)
    #expect(store.valuedPositions.first?.instrument == realOp)
  }
}

/// Actor-isolated test stub modelling the `.knownZero` flip a
/// `setStatus(.spam)` produces in production.
private actor MutableKnownZeroConversionService: InstrumentConversionService {
  private let rates: [String: Decimal]
  private var knownZeroIds: Set<String> = []

  init(rates: [String: Decimal] = [:]) {
    self.rates = rates
  }

  func markKnownZero(_ id: String) {
    knownZeroIds.insert(id)
  }

  func convert(
    _ quantity: Decimal, from: Instrument, to: Instrument, on date: Date
  ) async throws -> Decimal {
    if from.id == to.id { return quantity }
    if knownZeroIds.contains(from.id) {
      throw ConversionError.noProviderMapping(instrumentId: from.id)
    }
    return quantity * (rates[from.id] ?? 1)
  }

  func convertAmount(
    _ amount: InstrumentAmount, to instrument: Instrument, on date: Date
  ) async throws -> InstrumentAmount {
    guard amount.instrument != instrument else { return amount }
    let converted = try await convert(
      amount.quantity, from: amount.instrument, to: instrument, on: date)
    return InstrumentAmount(quantity: converted, instrument: instrument)
  }

  func convertResult(
    _ amount: InstrumentAmount, to instrument: Instrument, on date: Date
  ) async throws -> ConversionResult {
    if amount.instrument == instrument { return .value(amount) }
    if knownZeroIds.contains(amount.instrument.id) {
      return .knownZero(targetInstrument: instrument)
    }
    let converted = try await convertAmount(amount, to: instrument, on: date)
    return .value(converted)
  }

  func invalidateCache(for instrument: Instrument) async {}

  nonisolated func observeRates() -> AsyncStream<Void> {
    AsyncStream { continuation in
      continuation.yield(())
      continuation.finish()
    }
  }

  nonisolated func observeErrors() -> AsyncStream<any Error> {
    AsyncStream { $0.finish() }
  }
}
