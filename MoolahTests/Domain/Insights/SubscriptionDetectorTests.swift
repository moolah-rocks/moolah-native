import Foundation
import Testing

@testable import Moolah

@Suite("PayeeNormalizer")
struct PayeeNormalizerTests {
  @Test
  func stripsStoreNumbers() {
    #expect(PayeeNormalizer.normalize("STARBUCKS #1234") == "starbucks")
    #expect(PayeeNormalizer.normalize("Starbucks 5678") == "starbucks")
  }

  @Test
  func dropsLeadingNoiseToken() {
    #expect(PayeeNormalizer.normalize("POS STARBUCKS 9001") == "starbucks")
  }

  @Test
  func variantsFoldTogether() {
    let left = PayeeNormalizer.normalize("STARBUCKS #1234")
    let right = PayeeNormalizer.normalize("starbucks  #99")
    #expect(left == right)
  }

  @Test
  func emptyAndNil() {
    #expect(PayeeNormalizer.normalize(nil).isEmpty)
    #expect(PayeeNormalizer.normalize("   ").isEmpty)
  }
}

@Suite("SubscriptionDetector")
struct SubscriptionDetectorTests {
  private let calendar = InsightTestSupport.calendar

  private func payees(_ legs: [InsightTransaction]) -> [PayeeSummary] {
    InsightTestSupport.payees(from: legs)
  }

  @Test
  func detectsMonthlyStream() throws {
    let legs = [
      InsightTestSupport.expense(15.99, payee: "Netflix", daysAgo: 90),
      InsightTestSupport.expense(15.99, payee: "Netflix", daysAgo: 60),
      InsightTestSupport.expense(15.99, payee: "Netflix", daysAgo: 30),
      InsightTestSupport.expense(15.99, payee: "Netflix", daysAgo: 0),
    ]
    let detected = SubscriptionDetector.detect(payees: payees(legs), calendar: calendar)
    let netflix = try #require(detected.first { $0.normalizedPayee == "netflix" })
    #expect(netflix.period == .monthly)
    #expect(netflix.occurrenceCount == 4)
    #expect(netflix.medianAmount < 0)
  }

  @Test
  func ignoresIrregularSpending() {
    let legs = [
      InsightTestSupport.expense(5, payee: "Corner Cafe", daysAgo: 51),
      InsightTestSupport.expense(25, payee: "Corner Cafe", daysAgo: 40),
      InsightTestSupport.expense(8, payee: "Corner Cafe", daysAgo: 9),
      InsightTestSupport.expense(31, payee: "Corner Cafe", daysAgo: 2),
    ]
    let detected = SubscriptionDetector.detect(payees: payees(legs), calendar: calendar)
    #expect(detected.isEmpty)
  }

  @Test
  func detectsWeeklyCadence() throws {
    let legs = (0..<5).map { index in
      InsightTestSupport.expense(12, payee: "Gym", daysAgo: index * 7)
    }
    let detected = SubscriptionDetector.detect(payees: payees(legs), calendar: calendar)
    let gym = try #require(detected.first)
    #expect(gym.period == .weekly)
  }

  @Test
  func detectsIncomeStreamWhenRequested() throws {
    let legs = [
      InsightTestSupport.income(3000, payee: "ACME Payroll", daysAgo: 42),
      InsightTestSupport.income(3000, payee: "ACME Payroll", daysAgo: 28),
      InsightTestSupport.income(3000, payee: "ACME Payroll", daysAgo: 14),
      InsightTestSupport.income(3000, payee: "ACME Payroll", daysAgo: 0),
    ]
    let detected = SubscriptionDetector.detect(
      payees: payees(legs), incomeStreams: true, calendar: calendar)
    let payroll = try #require(detected.first)
    #expect(payroll.isIncome)
    #expect(payroll.period == .fortnightly)
    #expect(payroll.medianAmount > 0)
  }

  @Test
  func expenseDetectionExcludesIncome() {
    let legs = [
      InsightTestSupport.income(3000, payee: "ACME Payroll", daysAgo: 28),
      InsightTestSupport.income(3000, payee: "ACME Payroll", daysAgo: 14),
      InsightTestSupport.income(3000, payee: "ACME Payroll", daysAgo: 0),
    ]
    let detected = SubscriptionDetector.detect(payees: payees(legs), calendar: calendar)
    #expect(detected.isEmpty)
  }
}
