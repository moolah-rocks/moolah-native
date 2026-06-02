import Foundation
import Testing

@testable import Moolah

@Suite("Subscription insights")
struct SubscriptionInsightsTests {
  private let calendar = InsightTestSupport.calendar
  private let context = InsightTestSupport.context()

  private func detect(_ legs: [InsightTransaction]) -> [DetectedSubscription] {
    SubscriptionDetector.detect(
      payees: InsightTestSupport.payees(from: legs), calendar: calendar)
  }

  @Test
  func newRecurringFiresForFreshlyMaturedStream() {
    let transactions = [
      InsightTestSupport.expense(9.99, payee: "Spotify", daysAgo: 58),
      InsightTestSupport.expense(9.99, payee: "Spotify", daysAgo: 30),
      InsightTestSupport.expense(9.99, payee: "Spotify", daysAgo: 3),
    ]
    let insights = SubscriptionInsights.newRecurring(detect(transactions), context: context)
    #expect(insights.contains { $0.kind == .newRecurringDetected })
  }

  @Test
  func newRecurringStaysQuietForOldStream() {
    let transactions = (0..<6).map { index in
      InsightTestSupport.expense(9.99, payee: "Spotify", daysAgo: index * 30)
    }
    let insights = SubscriptionInsights.newRecurring(detect(transactions), context: context)
    #expect(insights.isEmpty)
  }

  @Test
  func priceHikeDetectsIncrease() throws {
    let transactions = [
      InsightTestSupport.expense(10, payee: "CloudStore", daysAgo: 90),
      InsightTestSupport.expense(10, payee: "CloudStore", daysAgo: 60),
      InsightTestSupport.expense(10, payee: "CloudStore", daysAgo: 30),
      InsightTestSupport.expense(12, payee: "CloudStore", daysAgo: 0),
    ]
    let insights = SubscriptionInsights.priceHikes(detect(transactions), context: context)
    let hike = try #require(insights.first)
    #expect(hike.kind == .subscriptionPriceHike)
    #expect(hike.framing == .negative)
  }

  @Test
  func priceHikeQuietWhenStable() {
    let transactions = (0..<4).map { index in
      InsightTestSupport.expense(10, payee: "CloudStore", daysAgo: index * 30)
    }
    let insights = SubscriptionInsights.priceHikes(detect(transactions), context: context)
    #expect(insights.isEmpty)
  }

  @Test
  func duplicateSubscriptionsInSameCategory() throws {
    let streaming = Category(name: "Streaming")
    let categories = Categories(from: [streaming])
    var transactions: [InsightTransaction] = []
    for index in 0..<4 {
      transactions.append(
        InsightTestSupport.expense(
          15, payee: "Netflix", daysAgo: index * 30, categoryId: streaming.id,
          categoryPath: "Streaming"))
      transactions.append(
        InsightTestSupport.expense(
          16, payee: "Disney Plus", daysAgo: index * 30, categoryId: streaming.id,
          categoryPath: "Streaming"))
    }
    let insights = SubscriptionInsights.duplicates(
      detect(transactions), categories: categories, context: context)
    let duplicate = try #require(insights.first)
    #expect(duplicate.kind == .duplicateSubscription)
    #expect(duplicate.actionability == .act)
  }

  @Test
  func subscriptionOverspendFlagsHighShare() {
    let transactions = (0..<4).flatMap { index in
      [
        InsightTestSupport.expense(40, payee: "BigBundle", daysAgo: index * 30),
        InsightTestSupport.expense(35, payee: "MegaStream", daysAgo: index * 30),
      ]
    }
    let subscriptions = detect(transactions)
    let insights = SavingsOpportunityInsights.subscriptionOverspend(
      subscriptions: subscriptions, averageMonthlyIncome: 300, context: context)
    #expect(insights.contains { $0.kind == .subscriptionOverspend })
  }
}
