import Foundation
import Testing

@testable import Moolah

@Suite("InsightRanker")
struct InsightRankerTests {
  private let now = InsightTestSupport.now

  private func insight(
    id: String,
    kind: InsightKind = .largeTransactionAnomaly,
    framing: InsightFraming = .negative,
    actionability: InsightActionability = .review,
    surprise: Double = 0.5,
    impact: Decimal? = nil,
    date: Date? = nil
  ) -> Insight {
    Insight(
      id: id, kind: kind, title: id, date: date ?? now, framing: framing,
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
