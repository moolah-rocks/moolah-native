import Foundation
import Testing

@testable import Moolah

@Suite("GRDBAnalysisRepository — conversion pre-warm collection")
struct GRDBAnalysisPrewarmTests {

  private func context(profile: Instrument) -> GRDBAnalysisRepository.DailyBalancesAssemblyContext {
    GRDBAnalysisRepository.DailyBalancesAssemblyContext(
      investmentAccountIds: [],
      tradesModeInvestmentAccountIds: [],
      instrumentMap: [:],
      profileInstrument: profile,
      conversionService: StubConversionService())
  }

  private func accountRow(
    day: String, sample: Date, instrument: String
  ) -> GRDBAnalysisRepository.DailyBalanceAccountRow {
    GRDBAnalysisRepository.DailyBalanceAccountRow(
      day: day, sampleDate: sample, accountId: UUID(), instrumentId: instrument,
      type: "transfer", qty: 100_000_000)
  }

  private func earmarkRow(
    day: String, sample: Date, instrument: String
  ) -> GRDBAnalysisRepository.DailyBalanceEarmarkRow {
    GRDBAnalysisRepository.DailyBalanceEarmarkRow(
      day: day, sampleDate: sample, earmarkId: UUID(), instrumentId: instrument,
      type: "transfer", qty: 100_000_000)
  }

  /// The collected warm-ups must be the *running union* of instruments —
  /// each day carries every instrument seen up to and including that day,
  /// at that day's representative instant, mirroring what the per-day walk
  /// converts. The profile instrument is excluded (the walk's same-instrument
  /// fast path skips it). Prior rows seed the union from day zero.
  @Test("running union across days, seeded by prior rows, excludes the profile instrument")
  func collectsRunningUnion() {
    let aud = Instrument.fiat(code: "AUD")
    let day1 = Date(timeIntervalSince1970: 1_000_000)
    let day2 = Date(timeIntervalSince1970: 1_100_000)

    let warmups = GRDBAnalysisRepository.collectConversionWarmups(
      priorAccountRows: [accountRow(day: "2025-12-31", sample: day1, instrument: "USD")],
      priorEarmarkRows: [],
      accountRows: [
        accountRow(day: "2026-01-01", sample: day1, instrument: "EUR"),
        // AUD == profile instrument: must never be warmed.
        accountRow(day: "2026-01-01", sample: day1, instrument: "AUD"),
        accountRow(day: "2026-01-02", sample: day2, instrument: "GBP"),
      ],
      earmarkRows: [],
      context: context(profile: aud))

    // Compare as a set of (instrument id, date) — inner ordering is irrelevant.
    let got = Set(warmups.map { Pair(id: $0.instrument.id, date: $0.date) })
    let expected: Set<Pair> = [
      // Day 1: USD (prior) + EUR (day-1 delta), at day1's instant.
      Pair(id: "USD", date: day1), Pair(id: "EUR", date: day1),
      // Day 2: USD + EUR carried forward + GBP (day-2 delta), at day2's instant.
      Pair(id: "USD", date: day2), Pair(id: "EUR", date: day2), Pair(id: "GBP", date: day2),
    ]
    #expect(got == expected)
  }

  /// A single-instrument profile (every position already in the profile
  /// instrument) needs no conversions — the collection is empty so the
  /// pre-warm is a no-op.
  @Test("no warm-ups when every instrument is the profile instrument")
  func emptyWhenAllProfileInstrument() {
    let aud = Instrument.fiat(code: "AUD")
    let warmups = GRDBAnalysisRepository.collectConversionWarmups(
      priorAccountRows: [accountRow(day: "2025-12-31", sample: Date(), instrument: "AUD")],
      priorEarmarkRows: [],
      accountRows: [accountRow(day: "2026-01-01", sample: Date(), instrument: "AUD")],
      earmarkRows: [],
      context: context(profile: aud))
    #expect(warmups.isEmpty)
  }

  /// Earmark instruments feed the same running union as account
  /// instruments — both the prior-row seed (`priorEarmarkRows`) and the
  /// per-day growth (`earmarkRows`) must surface in the warm-ups.
  @Test("earmark rows seed and grow the running union too")
  func collectsEarmarkInstruments() {
    let aud = Instrument.fiat(code: "AUD")
    let day1 = Date(timeIntervalSince1970: 2_000_000)
    let day2 = Date(timeIntervalSince1970: 2_100_000)

    let warmups = GRDBAnalysisRepository.collectConversionWarmups(
      priorAccountRows: [],
      priorEarmarkRows: [earmarkRow(day: "2025-12-31", sample: day1, instrument: "USD")],
      accountRows: [accountRow(day: "2026-01-02", sample: day2, instrument: "EUR")],
      earmarkRows: [earmarkRow(day: "2026-01-01", sample: day1, instrument: "GBP")],
      context: context(profile: aud))

    let got = Set(warmups.map { Pair(id: $0.instrument.id, date: $0.date) })
    let expected: Set<Pair> = [
      // Day 1 (earmark slice): USD (prior earmark) + GBP (day-1 earmark).
      Pair(id: "USD", date: day1), Pair(id: "GBP", date: day1),
      // Day 2 (account slice): USD + GBP carried forward + EUR (day-2 account).
      Pair(id: "USD", date: day2), Pair(id: "GBP", date: day2), Pair(id: "EUR", date: day2),
    ]
    #expect(got == expected)
  }

  private struct Pair: Hashable {
    let id: String
    let date: Date
  }
}
