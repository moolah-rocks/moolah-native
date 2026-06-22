import Foundation
import Testing

@testable import Moolah

/// Rule 11 (`INSTRUMENT_CONVERSION_GUIDE.md`) for the forecast tail:
/// a per-instance conversion failure during forecast pre-conversion
/// must NOT abort the whole forecast. Every sibling analysis path
/// (historic walk, investment values, trades-mode fold, forecast
/// accumulator) already degrades per-unit; the forecast pre-conversion
/// step was the one path that rethrew, surfacing on the Analysis page
/// as a full-screen sync error.
@Suite("GRDBAnalysisRepository.generateForecast — Rule 11 contract")
struct GRDBForecastRule11Tests {
  private func monthlyFrom(_ start: Date, leg: TransactionLeg) -> Transaction {
    Transaction(
      date: start,
      payee: "Recurring",
      recurPeriod: .month,
      recurEvery: 1,
      legs: [leg])
  }

  /// The regression: a recurring scheduled transaction whose leg can
  /// never price (no provider mapping) made forecast pre-conversion
  /// rethrow, escaping all the way to `AnalysisStore` as a full-screen
  /// error. The fix degrades the failing instances per Rule 11 instead,
  /// so the call returns normally (the affected forecast days simply
  /// drop out, exactly like every sibling analysis path).
  @Test("An unpriceable recurring leg degrades instead of aborting the forecast")
  func unpriceableInstanceDoesNotAbortForecast() async throws {
    let aud = Instrument.AUD
    let unmapped = Instrument.crypto(
      chainId: 1,
      contractAddress: "0xabcabcabcabcabcabcabcabcabcabcabcabcabc0",
      symbol: "ZZZ", name: "Unlisted Token", decimals: 18)

    let start = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    let endDate = Calendar.current.date(byAdding: .month, value: 4, to: Date()) ?? Date()

    let failing = monthlyFrom(
      start,
      leg: TransactionLeg(
        accountId: UUID(), instrument: unmapped, quantity: 1, type: .expense))

    let conversion = FakeConversionService.failingInstruments([unmapped.id])
    let context = GRDBAnalysisRepository.DailyBalancesAssemblyContext(
      investmentAccountIds: [],
      tradesModeInvestmentAccountIds: [],
      instrumentMap: [unmapped.id: unmapped, aud.id: aud],
      profileInstrument: aud,
      conversionService: conversion)

    // Before the fix this threw `FakeConversionError.instrumentUnavailable`
    // out of `preConvertForecastInstances`; the contract is that it
    // returns normally (degraded) instead.
    let result = try await GRDBAnalysisRepository.generateForecast(
      scheduled: [failing],
      startingBook: .empty,
      endDate: endDate,
      context: context)

    // Every instance's day is dropped (Rule 11 — never a partial day),
    // so the result is empty, but crucially the call did NOT throw.
    #expect(result.isEmpty)
  }

  @Test("Cooperative cancellation still propagates from forecast pre-conversion")
  func cancellationStillPropagates() async throws {
    let aud = Instrument.AUD
    let token = Instrument.crypto(
      chainId: 1, contractAddress: "0xabcabcabcabcabcabcabcabcabcabcabcabcabc0",
      symbol: "ZZZ", name: "Unlisted", decimals: 18)
    let start = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    let endDate = Calendar.current.date(byAdding: .month, value: 2, to: Date()) ?? Date()
    let failing = monthlyFrom(
      start,
      leg: TransactionLeg(accountId: UUID(), instrument: token, quantity: 1, type: .expense))
    let context = GRDBAnalysisRepository.DailyBalancesAssemblyContext(
      investmentAccountIds: [],
      tradesModeInvestmentAccountIds: [],
      instrumentMap: [token.id: token, aud.id: aud],
      profileInstrument: aud,
      conversionService: CancellingConversionService())

    await #expect(throws: CancellationError.self) {
      _ = try await GRDBAnalysisRepository.generateForecast(
        scheduled: [failing],
        startingBook: .empty,
        endDate: endDate,
        context: context)
    }
  }
}

/// Conversion service that always reports cooperative cancellation, to
/// pin the invariant that `CancellationError` is *not* folded into the
/// per-instance degradation path.
private actor CancellingConversionService: InstrumentConversionService {
  func convert(
    _ quantity: Decimal, from: Instrument, to: Instrument, on date: Date
  ) async throws -> Decimal {
    if from.id == to.id { return quantity }
    throw CancellationError()
  }

  func convertAmount(
    _ amount: InstrumentAmount, to instrument: Instrument, on date: Date
  ) async throws -> InstrumentAmount {
    guard amount.instrument != instrument else { return amount }
    throw CancellationError()
  }

  func convertResult(
    _ amount: InstrumentAmount, to instrument: Instrument, on date: Date
  ) async throws -> ConversionResult {
    guard amount.instrument != instrument else { return .value(amount) }
    throw CancellationError()
  }

  func invalidateCache(for instrument: Instrument) async {}

  nonisolated func observeRates() -> AsyncStream<Void> {
    AsyncStream { $0.finish() }
  }

  nonisolated func observeErrors() -> AsyncStream<any Error> {
    AsyncStream { $0.finish() }
  }
}
