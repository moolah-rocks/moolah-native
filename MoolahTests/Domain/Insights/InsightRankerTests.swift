import Foundation
import Testing

@testable import Moolah

@Suite("InsightRanker")
struct InsightRankerTests {
  private let now = InsightTestSupport.now

  private func insight(
    id: String,
    presentationKey: String? = nil,
    kind: InsightKind = .largeTransactionAnomaly,
    framing: InsightFraming = .negative,
    actionability: InsightActionability = .review,
    surprise: Double = 0.5,
    impact: Decimal? = nil,
    date: Date? = nil
  ) -> Insight {
    Insight(
      id: id, presentationKey: presentationKey, kind: kind, title: id,
      date: date ?? now, framing: framing,
      actionability: actionability, surprise: surprise,
      monetaryImpact: impact.map { InsightTestSupport.amount($0) })
  }

  @Test
  func higherSignalRanksFirst() {
    let strong = insight(id: "strong", surprise: 0.95, impact: 5000)
    let weak = insight(id: "weak", surprise: 0.1, impact: 5)
    let ranked = InsightRanker().rank([weak, strong], now: now)
    #expect(ranked.first?.id == "strong")
  }

  @Test
  func fatiguePenaltyLowersScore() {
    let ranker = InsightRanker()
    let candidate = insight(id: "x", kind: .newMerchantAlert, surprise: 0.6)
    let base = ranker.score(candidate, now: now)
    let fatigued = ranker.score(candidate, now: now, dismissals: [.newMerchantAlert: 2])
    #expect(fatigued < base)
  }

  @Test("displaying an insight today does not downscore it until tomorrow")
  func sameDayDisplayKeepsScore() {
    let ranker = InsightRanker(displayCalendar: InsightContext.defaultCalendar)
    let candidate = insight(id: "cash", presentationKey: "idle-cash")
    let morning = now
    let evening = now.addingTimeInterval(60 * 60 * 8)

    let fresh = ranker.score(candidate, now: evening)
    let shownToday = ranker.score(
      candidate, now: evening, displayHistory: ["idle-cash": morning])

    #expect(shownToday == fresh)
  }

  @Test("yesterday's insight is downscored more than an older display")
  func displayPenaltyDecaysOverTime() throws {
    let ranker = InsightRanker(displayCalendar: InsightContext.defaultCalendar)
    let candidate = insight(id: "cash", presentationKey: "idle-cash")
    let yesterday = try #require(
      ranker.calendar.date(byAdding: .day, value: -1, to: now))
    let weekAgo = try #require(
      ranker.calendar.date(byAdding: .day, value: -7, to: now))

    let recentScore = ranker.score(
      candidate, now: now, displayHistory: ["idle-cash": yesterday])
    let olderScore = ranker.score(
      candidate, now: now, displayHistory: ["idle-cash": weekAgo])

    #expect(recentScore < olderScore)
  }

  @Test("separate payments of the same kind have separate display fatigue")
  func eventSpecificKeysAreIndependent() throws {
    let ranker = InsightRanker(displayCalendar: InsightContext.defaultCalendar)
    let first = insight(id: "payment-1", presentationKey: "payment-1")
    let second = insight(id: "payment-2", presentationKey: "payment-2")
    let yesterday = try #require(
      ranker.calendar.date(byAdding: .day, value: -1, to: now))
    let history = ["payment-1": yesterday]

    #expect(
      ranker.score(first, now: now, displayHistory: history)
        < ranker.score(second, now: now, displayHistory: history))
  }

  @Test("changing figures share fatigue when the semantic insight is unchanged")
  func changingFiguresSharePresentationKey() throws {
    let ranker = InsightRanker(displayCalendar: InsightContext.defaultCalendar)
    let earlier = insight(id: "cash-10000", presentationKey: "idle-cash", impact: 10_000)
    let updated = insight(id: "cash-10500", presentationKey: "idle-cash", impact: 10_500)
    let yesterday = try #require(
      ranker.calendar.date(byAdding: .day, value: -1, to: now))
    let history = [earlier.presentationKey: yesterday]

    let fatigued = ranker.score(updated, now: now, displayHistory: history)
    let fresh = ranker.score(updated, now: now)

    #expect(fatigued < fresh)
  }

  @Test("an insight shown yesterday yields its slot to a fresh alternative")
  func recentDisplayRotatesRanking() throws {
    let ranker = InsightRanker(displayCalendar: InsightContext.defaultCalendar)
    let repeated = insight(id: "repeated", surprise: 0.7)
    let alternative = insight(id: "alternative", surprise: 0.5)
    let yesterday = try #require(
      ranker.calendar.date(byAdding: .day, value: -1, to: now))

    let ranked = ranker.rank(
      [repeated, alternative], now: now,
      displayHistory: [repeated.presentationKey: yesterday], displayCap: 1)

    #expect(ranked.first?.id == alternative.id)
  }

  @Test("display fatigue starts at midnight in the user's timezone")
  func displayDayUsesUserCalendar() throws {
    var brisbane = Calendar(identifier: .gregorian)
    brisbane.timeZone = try #require(TimeZone(identifier: "Australia/Brisbane"))
    let candidate = insight(id: "cash", presentationKey: "idle-cash")
    let shownAt = InsightTestSupport.date(2026, 6, 1).addingTimeInterval(13.5 * 60 * 60)
    let now = shownAt.addingTimeInterval(60 * 60)
    let history = [candidate.presentationKey: shownAt]

    let utcScore = InsightRanker(displayCalendar: InsightContext.defaultCalendar)
      .score(candidate, now: now, displayHistory: history)
    let localScore = InsightRanker(displayCalendar: brisbane)
      .score(candidate, now: now, displayHistory: history)

    #expect(localScore < utcScore)
  }

  @Test
  func deduplicatesById() {
    let ranked = InsightRanker().rank(
      [insight(id: "dup", surprise: 0.2), insight(id: "dup", surprise: 0.9)],
      now: now, displayCap: 10)
    #expect(ranked.count == 1)
  }

  @Test
  func respectsDisplayCap() {
    let candidates = (0..<10).map { insight(id: "i\($0)", surprise: Double($0) / 10) }
    let ranked = InsightRanker().rank(candidates, now: now, displayCap: 3)
    #expect(ranked.count == 3)
  }

  @Test
  func guaranteesOnePositiveInsight() {
    var candidates = (0..<5).map {
      insight(id: "neg\($0)", framing: .negative, surprise: 0.9, impact: 9000)
    }
    candidates.append(
      insight(id: "pos", framing: .positive, surprise: 0.1, impact: 1))
    let ranked = InsightRanker().rank(
      candidates, now: now, displayCap: 5, guaranteePositive: true)
    #expect(ranked.count == 5)
    #expect(ranked.contains { $0.insight.framing == .positive })
  }

  @Test
  func declaredInterestBoostsScore() {
    let categoryId = UUID()
    let ranker = InsightRanker()
    let plain = Insight(
      id: "plain", kind: .categoryTrendRising, title: "", date: now,
      framing: .neutral, actionability: .review, surprise: 0.5)
    let pinned = Insight(
      id: "pinned", kind: .categoryTrendRising, title: "", date: now,
      framing: .neutral, actionability: .review, surprise: 0.5,
      references: InsightReferences(categoryIds: [categoryId]))
    let interests = InsightRanker.DeclaredInterests(categoryIds: [categoryId])
    let plainScore = ranker.score(plain, now: now)
    let pinnedScore = ranker.score(pinned, now: now, interests: interests)
    #expect(pinnedScore > plainScore)
  }
}
