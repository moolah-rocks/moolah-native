import Foundation
import Testing

@testable import Moolah

@Suite("Repeated insights yield to fresh observations")
struct InsightRepeatFatigueTests {
  private let now = InsightTestSupport.now
  private let ranker = InsightRanker(displayCalendar: .utc)

  @Test
  func recordingAnotherDisplayDoesNotRestoreFreshScore() throws {
    let milestone = try milestone(current: 10500)
    let yesterday = InsightTestSupport.daysAgo(1)
    let beforeRefresh = ranker.score(
      milestone, now: now, displayHistory: [milestone.presentationKey: yesterday])
    let afterRefresh = ranker.score(
      milestone, now: now, displayHistory: [milestone.presentationKey: now])
    #expect(afterRefresh <= beforeRefresh)
  }

  @Test
  func positiveGuaranteeDoesNotRestoreRecentlyShownMilestone() throws {
    let milestone = try milestone(current: 10500)
    let alternative = freshAlternative()
    let ranked = ranker.rank(
      [milestone, alternative], now: now,
      displayHistory: [milestone.presentationKey: now], displayCap: 1)
    #expect(ranked.first?.id == alternative.id)
  }

  @Test
  func positiveGuaranteeCanReturnAfterAWeekWithoutDisplay() throws {
    let milestone = try milestone(current: 10500)
    let alternative = freshAlternative()
    let ranked = ranker.rank(
      [milestone, alternative], now: now,
      displayHistory: [milestone.presentationKey: InsightTestSupport.daysAgo(7)], displayCap: 1)
    #expect(ranked.first?.id == milestone.id)
  }

  @Test
  func changingNetWorthKeepsMilestoneDisplayHistory() throws {
    let earlier = try milestone(current: 10500)
    let updated = try milestone(current: 10900)
    #expect(updated.presentationKey == earlier.presentationKey)
    let freshScore = ranker.score(updated, now: now)
    let repeatedScore = ranker.score(
      updated, now: now, displayHistory: [earlier.presentationKey: now])
    #expect(repeatedScore < freshScore)
  }

  @Test
  func newMilestoneHasIndependentDisplayHistory() throws {
    let earlier = try milestone(current: 10500)
    let updated = try milestone(current: 20500)
    #expect(updated.presentationKey != earlier.presentationKey)
    #expect(
      ranker.score(updated, now: now, displayHistory: [earlier.presentationKey: now])
        == ranker.score(updated, now: now))
  }

  @Test
  func milestoneRecencyUsesCrossingDate() throws {
    let insight = try milestone(current: 10900)
    #expect(insight.date == InsightTestSupport.daysAgo(10))
  }

  @Test
  func milestoneImpactMeasuresGrowthRatherThanTotalWealth() throws {
    let insight = try milestone(current: 10900)
    #expect(insight.monetaryImpact == InsightTestSupport.amount(1400))
  }

  @Test
  func milestoneRecrossingUsesLatestCrossing() throws {
    let balances = [
      balance(9500, daysAgo: 40), balance(10500, daysAgo: 30),
      balance(9900, daysAgo: 20), balance(10200, daysAgo: 10),
      balance(10900, daysAgo: 0),
    ]
    let insight = try #require(
      NetWorthInsights.detect(dailyBalances: balances, context: InsightTestSupport.context()).first)
    #expect(insight.date == InsightTestSupport.daysAgo(10))
  }

  private func milestone(current: Decimal) throws -> Insight {
    try #require(
      NetWorthInsights.detect(
        dailyBalances: [
          balance(9500, daysAgo: 40), balance(10200, daysAgo: 10), balance(current, daysAgo: 0),
        ], context: InsightTestSupport.context()
      ).first)
  }

  private func balance(_ value: Decimal, daysAgo: Int) -> DailyBalance {
    DailyBalance(
      date: InsightTestSupport.daysAgo(daysAgo), balance: InsightTestSupport.amount(value))
  }

  private func freshAlternative() -> Insight {
    Insight(
      id: "fresh-charge", kind: .largeTransactionAnomaly, title: "Review this charge",
      date: now, framing: .negative, actionability: .review, surprise: 0.9,
      monetaryImpact: InsightTestSupport.amount(1000))
  }
}
