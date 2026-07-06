import Foundation
import Testing

@testable import Moolah

@Suite("AccountPerformanceTileLabels")
struct AccountPerformanceTileLabelsTests {
  let aud = Instrument.AUD

  private func performance(
    currentValue: Decimal? = nil,
    amountInvested: Decimal? = nil,
    profitLoss: Decimal? = nil,
    firstFlowDate: Date? = nil
  ) -> AccountPerformance {
    AccountPerformance(
      instrument: aud,
      currentValue: currentValue.map { InstrumentAmount(quantity: $0, instrument: aud) },
      amountInvested: amountInvested.map {
        InstrumentAmount(quantity: $0, instrument: aud)
      },
      profitLoss: profitLoss.map { InstrumentAmount(quantity: $0, instrument: aud) },
      profitLossPercent: nil,
      annualisedReturn: nil,
      firstFlowDate: firstFlowDate
    )
  }

  @Test("subtitle shows Amount invested $X when both flowDate and amountInvested populated")
  func subtitleShowsInvested() {
    let perf = performance(
      currentValue: 12_000, amountInvested: 10_000,
      firstFlowDate: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let expected =
      "Amount invested \(InstrumentAmount(quantity: 10_000, instrument: aud).formatted)"
    #expect(AccountPerformanceTileLabels.investedSubtitleText(perf) == expected)
  }

  @Test("subtitle shows Amount invested em-dash when flowDate set but amountInvested nil")
  func subtitleShowsUnavailable() {
    let perf = performance(
      currentValue: 12_000, amountInvested: nil,
      firstFlowDate: Date(timeIntervalSince1970: 1_700_000_000)
    )
    #expect(AccountPerformanceTileLabels.investedSubtitleText(perf) == "Amount invested —")
  }

  @Test("subtitle hidden when no flows yet")
  func subtitleHiddenNoFlows() {
    let perf = performance(currentValue: 12_000, amountInvested: nil, firstFlowDate: nil)
    #expect(AccountPerformanceTileLabels.investedSubtitleText(perf) == nil)
  }

  @Test("accessibility label combines both fields when both populated")
  func accessibilityBothPopulated() {
    let perf = performance(
      currentValue: 12_000, amountInvested: 10_000,
      firstFlowDate: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let valueText = InstrumentAmount(quantity: 12_000, instrument: aud).formatted
    let inv = InstrumentAmount(quantity: 10_000, instrument: aud).formatted
    #expect(
      AccountPerformanceTileLabels.currentValueAccessibilityLabel(perf)
        == "Current Value: \(valueText), Amount invested: \(inv)"
    )
  }

  @Test("accessibility label when currentValue nil but amountInvested populated")
  func accessibilityCurrentValueNil() {
    let perf = performance(
      amountInvested: 10_000,
      firstFlowDate: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let inv = InstrumentAmount(quantity: 10_000, instrument: aud).formatted
    #expect(
      AccountPerformanceTileLabels.currentValueAccessibilityLabel(perf)
        == "Current Value: Unavailable, Amount invested: \(inv)"
    )
  }

  @Test("accessibility label when currentValue populated but amountInvested nil")
  func accessibilityContributionsNil() {
    let perf = performance(
      currentValue: 12_000,
      firstFlowDate: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let valueText = InstrumentAmount(quantity: 12_000, instrument: aud).formatted
    #expect(
      AccountPerformanceTileLabels.currentValueAccessibilityLabel(perf)
        == "Current Value: \(valueText), Amount invested: Unavailable"
    )
  }

  @Test("accessibility label drops Amount invested clause when no flows yet")
  func accessibilityNoFlowsClause() {
    let perf = performance(currentValue: 12_000, firstFlowDate: nil)
    let valueText = InstrumentAmount(quantity: 12_000, instrument: aud).formatted
    #expect(
      AccountPerformanceTileLabels.currentValueAccessibilityLabel(perf)
        == "Current Value: \(valueText)"
    )
  }

  @Test("accessibility label when both nil and no flows")
  func accessibilityAllUnavailable() {
    let perf = performance()
    #expect(
      AccountPerformanceTileLabels.currentValueAccessibilityLabel(perf)
        == "Current Value: Unavailable"
    )
  }
}
