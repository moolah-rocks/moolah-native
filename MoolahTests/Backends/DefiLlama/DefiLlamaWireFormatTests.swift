import Foundation
import Testing

@testable import Moolah

@Suite("DefiLlamaWireFormat")
struct DefiLlamaWireFormatTests {
  private func queryItems(_ url: URL) -> [String: String] {
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    return Dictionary(
      uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
  }

  @Test("chart URL oversamples at 12h so every UTC day gets a point")
  func chartURLOversamples() {
    // DefiLlama's `period=1d` series snaps each point to the nearest real
    // observation (~00:00 / ~23:59), which aliases against UTC-day buckets and
    // drops ~1 day in 5. Oversampling at 12h (2 points/day) guarantees ≥1 point
    // lands in every UTC day, so `parseChart`'s last-per-day bucketing is dense.
    let from = Date(timeIntervalSince1970: 1_725_148_800)  // 2024-09-01 UTC
    let to = Date(timeIntervalSince1970: 1_727_654_400)  // 2024-09-30 UTC (29 days later)
    let items = queryItems(
      DefiLlamaWireFormat.chartURL(coinId: "coingecko:ethereum", from: from, to: to))

    #expect(items["period"] == "12h")
    #expect(items["start"] == "1725148800")
    // Inclusive day count (29 + 1) + 2-day buffer = 32 days, at 2 points/day.
    #expect(items["span"] == "64")
  }

  @Test("a single-day window still oversamples at 12h")
  func chartURLSingleDayOversamples() {
    let day = Date(timeIntervalSince1970: 1_725_148_800)  // 2024-09-01 UTC
    let items = queryItems(
      DefiLlamaWireFormat.chartURL(coinId: "coingecko:ethereum", from: day, to: day))

    #expect(items["period"] == "12h")
    // (0 + 1) inclusive + 2-day buffer = 3 days, at 2 points/day.
    #expect(items["span"] == "6")
  }
}
