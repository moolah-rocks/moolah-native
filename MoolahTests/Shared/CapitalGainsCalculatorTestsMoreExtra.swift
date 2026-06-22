import Foundation
import Testing

@testable import Moolah

@Suite("CapitalGainsCalculator — Part 3")
struct CapitalGainsCalculatorTestsMoreExtra {
  let aud = Instrument.fiat(code: "AUD")

  @Test
  func cryptoSwap_conversionUsesTransactionDate() async throws {
    let eth = cryptoInstrument("ETH")
    let uni = cryptoInstrument("UNI")
    let accountId = UUID()

    let buyTx = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -3000, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: eth, quantity: 1, type: .trade,
          categoryId: nil, earmarkId: nil),
      ])

    let swapTx = LegTransaction(
      date: date(200),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: eth, quantity: -1, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: uni, quantity: 500, type: .trade,
          categoryId: nil, earmarkId: nil),
      ])

    // Rate schedule:
    //   pre-date(100): no rates (1:1 fallback)
    //   date(100)..<date(365): ETH=4000 AUD, UNI=8 AUD  ← effective on swap date(200)
    //   date(365) onward:      ETH=10 AUD,   UNI=0.01 AUD  ← what `Date()` would resolve to
    //
    // Correct routing (tx.date=swap date(200)) → ETH proceeds 4000 AUD,
    // gain = 4000 − 3000 = 1000.
    // Mistake (`Date()` ≈ today, > date(365)) → proceeds 10 AUD, gain ≈ −2990.
    // Mistake (`buyTx.date`=date(0)) → 1:1 fallback, proceeds 1 AUD, gain = −2999.
    let service = FakeConversionService.dateRates([
      date(100): [eth.id: 4000, uni.id: 8],
      date(365): [eth.id: 10, uni.id: dec("0.01")],
    ])
    let result = try await CapitalGainsCalculator.computeWithConversion(
      transactions: [buyTx, swapTx],
      profileCurrency: aud,
      conversionService: service
    )

    #expect(result.events.count == 1)
    #expect(result.events[0].instrument.id == eth.id)
    #expect(result.events[0].gain == 1000)
  }

  // MARK: - Sign preservation through conversion (CLAUDE.md sign convention)
  //
  // `classifyLegsWithConversion` must pass each leg's natural (signed)
  // quantity through `InstrumentConversionService.convert` rather than
  // pre-applying `abs()` and rebuilding the sign afterwards. This keeps
  // the calculator faithful to the CLAUDE.md monetary sign convention and
  // matches the sign-preserving pattern used in the fiat-only
  // `classifyLegs`. The conversion service below records the sign of every
  // quantity it receives so the tests can assert the contract directly.

  private actor SignRecordingConversionService: InstrumentConversionService {
    private var calls: [(from: String, quantity: Decimal)] = []
    private let rates: [String: Decimal]

    init(rates: [String: Decimal]) {
      self.rates = rates
    }

    func convert(
      _ quantity: Decimal, from: Instrument, to: Instrument, on date: Date
    ) async throws -> Decimal {
      calls.append((from: from.id, quantity: quantity))
      if from.id == to.id { return quantity }
      let rate = rates[from.id] ?? 1
      return quantity * rate
    }

    func convertAmount(
      _ amount: InstrumentAmount, to instrument: Instrument, on date: Date
    ) async throws -> InstrumentAmount {
      let converted = try await convert(
        amount.quantity, from: amount.instrument, to: instrument, on: date
      )
      return InstrumentAmount(quantity: converted, instrument: instrument)
    }

    func convertResult(
      _ amount: InstrumentAmount, to instrument: Instrument, on date: Date
    ) async throws -> ConversionResult {
      let converted = try await convertAmount(amount, to: instrument, on: date)
      return .value(converted)
    }

    func invalidateCache(for instrument: Instrument) async {}

    // No-op observation stubs — see `FakeConversionService.observeRates`
    // for the rationale.
    nonisolated func observeRates() -> AsyncStream<Void> {
      AsyncStream { continuation in
        continuation.yield(())
        continuation.finish()
      }
    }

    nonisolated func observeErrors() -> AsyncStream<any Error> {
      AsyncStream { $0.finish() }
    }

    func recordedCalls() -> [(from: String, quantity: Decimal)] { calls }
  }

  /// Fiat outflow/inflow legs must pass their *signed* quantity through
  /// the conversion service so the sign convention is preserved end to
  /// end. An outflow leg (negative quantity) must arrive at the
  /// conversion service as a negative number; an inflow leg as positive.
  @Test
  func fiatLegs_passSignedQuantityToConversionService() async throws {
    let bhp = stockInstrument("BHP")
    let usd = Instrument.fiat(code: "USD")
    let accountId = UUID()

    let buyTx = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: usd, quantity: -2000, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: 100, type: .trade,
          categoryId: nil, earmarkId: nil),
      ])

    let sellTx = LegTransaction(
      date: date(400),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: -100, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: usd, quantity: 3000, type: .trade,
          categoryId: nil, earmarkId: nil),
      ])

    let service = SignRecordingConversionService(rates: ["USD": dec("1.5")])
    _ = try await CapitalGainsCalculator.computeWithConversion(
      transactions: [buyTx, sellTx],
      profileCurrency: aud,
      conversionService: service
    )

    let usdCalls = await service.recordedCalls().filter { $0.from == "USD" }
    #expect(usdCalls.count == 2)
    // Outflow leg (-2000 USD) must reach the conversion service with its
    // natural negative sign; inflow leg (+3000 USD) with its natural
    // positive sign. Any implementation that strips the sign before
    // conversion (e.g. `abs(leg.quantity)`) will fail this check.
    #expect(usdCalls.contains { $0.quantity == -2000 })
    #expect(usdCalls.contains { $0.quantity == 3000 })
  }

  /// Non-fiat swap legs must also preserve their sign across the
  /// conversion boundary. The outgoing leg of a swap is negative and must
  /// arrive at the conversion service as negative; the incoming leg as
  /// positive.
  @Test
  func cryptoSwap_passesSignedQuantityToConversionService() async throws {
    let eth = cryptoInstrument("ETH")
    let uni = cryptoInstrument("UNI")
    let accountId = UUID()

    let buyTx = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -3000, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: eth, quantity: 1, type: .trade,
          categoryId: nil, earmarkId: nil),
      ])

    let swapTx = LegTransaction(
      date: date(200),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: eth, quantity: -1, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: uni, quantity: 500, type: .trade,
          categoryId: nil, earmarkId: nil),
      ])

    let service = SignRecordingConversionService(rates: [eth.id: 4000, uni.id: 8])
    _ = try await CapitalGainsCalculator.computeWithConversion(
      transactions: [buyTx, swapTx],
      profileCurrency: aud,
      conversionService: service
    )

    let ethCalls = await service.recordedCalls().filter { $0.from == eth.id }
    let uniCalls = await service.recordedCalls().filter { $0.from == uni.id }
    // ETH is sold (leg.quantity == -1), UNI is bought (leg.quantity == 500).
    #expect(ethCalls.contains { $0.quantity == -1 })
    #expect(uniCalls.contains { $0.quantity == 500 })
  }

  // MARK: - Helpers

  private func stockInstrument(_ name: String) -> Instrument {
    Instrument.stock(ticker: "\(name).AX", exchange: "ASX", name: name)
  }

  private func cryptoInstrument(_ symbol: String) -> Instrument {
    Instrument(
      id: "1:\(symbol.lowercased())", kind: .cryptoToken, name: symbol, decimals: 8,
      ticker: nil, exchange: nil, chainId: 1, contractAddress: nil)
  }

  private func date(_ daysFromBase: Int) -> Date {
    let calendar = Calendar(identifier: .gregorian)
    guard
      let base = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1)),
      let result = calendar.date(byAdding: .day, value: daysFromBase, to: base)
    else {
      fatalError("Could not construct date \(daysFromBase) days from 2024-01-01")
    }
    return result
  }
}
