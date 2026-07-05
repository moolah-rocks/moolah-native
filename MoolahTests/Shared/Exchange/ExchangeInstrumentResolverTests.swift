import Testing

@testable import Moolah

@Suite("ExchangeInstrumentResolver")
struct ExchangeInstrumentResolverTests {
  private func op(_ contract: String, spam: Bool = false, mapped: Bool = true)
    -> CryptoRegistration
  {
    let inst = Instrument.crypto(
      chainId: 10, contractAddress: contract, symbol: "OP",
      name: "Optimism", decimals: 18)
    return CryptoRegistration(
      instrument: inst,
      mapping: CryptoProviderMapping(
        instrumentId: inst.id,
        coingeckoId: mapped ? "optimism" : nil,
        binanceSymbol: nil),
      pricingStatus: spam ? .spam : (mapped ? .priced : .unpriced))
  }

  private func resolver(
    _ regs: [CryptoRegistration],
    used: Set<String> = []
  ) -> ExchangeInstrumentResolver {
    ExchangeInstrumentResolver(
      registry: StubInstrumentRegistry(
        instruments: regs.map(\.instrument),
        cryptoRegistrations: regs),
      fiatInstrument: .AUD,
      existingLegInstrumentIds: { used })
  }

  @Test
  func fiatAccessorReturnsInjectedInstrument() {
    #expect(resolver([]).fiatDenomination() == .AUD)
  }

  @Test
  func fallbackExcludesSpamAndPicksRealOP() async throws {
    let spam = op("0xdeadbeef00000000000000000000000000000000", spam: true)
    let real = op("0x4200000000000000000000000000000000000042")
    let got = try await resolver([spam, real]).fallbackInstrument(forSymbol: "OP")
    #expect(got == real.instrument)
  }

  @Test
  func fallbackPrefersMappedOverUnpricedStub() async throws {
    let stub = op("0x1111111111111111111111111111111111111111", mapped: false)
    let mapped = op("0x4200000000000000000000000000000000000042")
    let got = try await resolver([stub, mapped]).fallbackInstrument(forSymbol: "OP")
    #expect(got == mapped.instrument)
  }

  @Test
  func fallbackPrefersUsedThenLowestId() async throws {
    let opA = op("0xaaaa000000000000000000000000000000000000")
    let opB = op("0xbbbb000000000000000000000000000000000000")
    let got = try await resolver([opA, opB], used: [opB.instrument.id])
      .fallbackInstrument(forSymbol: "OP")
    #expect(got == opB.instrument)
  }

  @Test
  func fallbackDeterministicIdTieBreak() async throws {
    let opA = op("0xaaaa000000000000000000000000000000000000")
    let opB = op("0xbbbb000000000000000000000000000000000000")
    let got = try await resolver([opB, opA]).fallbackInstrument(forSymbol: "OP")
    #expect(got == opA.instrument)
  }

  @Test
  func fallbackAllSpamReturnsNil() async throws {
    let got = try await resolver([op("0xdead000000000000000000000000000000000000", spam: true)])
      .fallbackInstrument(forSymbol: "OP")
    #expect(got == nil)
  }

  @Test
  func registeredInstrumentReturnsSeededRegistration() async throws {
    let real = op("0x4200000000000000000000000000000000000042")
    let got = try await resolver([real]).registeredInstrument(id: real.instrument.id)
    #expect(got == real.instrument)
  }
}
