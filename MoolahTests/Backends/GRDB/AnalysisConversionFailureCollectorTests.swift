import Foundation
import Testing

@testable import Moolah

@Suite("Analysis conversion failure summaries")
struct AnalysisConversionFailureCollectorTests {
  @Test("repeated failures for one instrument produce one counted summary")
  func repeatedFailuresAreCoalesced() throws {
    let collector = AnalysisConversionFailureCollector()
    let error = ConversionError.noProviderMapping(instrumentId: "1:token")

    collector.record(error, instrumentId: "1:token", context: "day=2026-01-01")
    collector.record(error, instrumentId: "1:token", context: "day=2026-01-02")

    let summaries = collector.summaries()
    #expect(summaries.count == 1)
    let summary = try #require(summaries.first)
    #expect(summary.count == 2)
    #expect(summary.sampleContext == "day=2026-01-01")
  }
}
