import Foundation
import Testing

@testable import Moolah

// Swift Testing's `@Test func foo()` is the documented idiom, and
// swift-format's `lineBreakBetweenDeclarationAttributes: false` keeps the
// attribute inline. Disable SwiftLint's `attributes` rule in this file so
// the formatter and the linter don't fight over the same layout.
// swiftlint:disable attributes

@Suite("ReportsPeriodStorage")
struct ReportsPeriodStorageTests {
  // Fixed instant (~2026) so relative-range resolution is deterministic.
  private let referenceToday = Date(timeIntervalSinceReferenceDate: 800_000_000)

  /// Tokens are a permanent persistence contract, decoupled from the enum's
  /// user-facing display strings. Locking a few literals here documents that a
  /// display-copy edit must NOT change the token, and that every case
  /// round-trips through `token(for:)` / `range(forToken:)`.
  @Test func tokens_areStableAndRoundTrip() {
    #expect(ReportsPeriodStorage.token(for: .last12Months) == "last12Months")
    #expect(ReportsPeriodStorage.token(for: .custom) == "custom")
    for range in DateRange.allCases {
      #expect(ReportsPeriodStorage.range(forToken: ReportsPeriodStorage.token(for: range)) == range)
    }
  }

  @Test func absentPreference_defaultsToLast12Months() {
    let seed = ReportsPeriodStorage.seed(
      storedRangeToken: nil, storedCustomFrom: nil, storedCustomTo: nil, today: referenceToday)

    #expect(seed.dateRange == .last12Months)
  }

  @Test func unknownStoredToken_defaultsToLast12Months() {
    let seed = ReportsPeriodStorage.seed(
      storedRangeToken: "retired token", storedCustomFrom: nil, storedCustomTo: nil,
      today: referenceToday)

    #expect(seed.dateRange == .last12Months)
  }

  @Test func relativePreset_resolvesViaDateRange() {
    let seed = ReportsPeriodStorage.seed(
      storedRangeToken: ReportsPeriodStorage.token(for: .last6Months),
      storedCustomFrom: nil, storedCustomTo: nil, today: referenceToday)

    let startOfToday = Calendar.current.startOfDay(for: referenceToday)
    #expect(seed.dateRange == .last6Months)
    #expect(seed.resolvedFrom == DateRange.last6Months.startDate(today: startOfToday))
    #expect(seed.resolvedTo == DateRange.last6Months.endDate(today: startOfToday))
  }

  /// The stored value is the *relative* preset, so resolving against a later
  /// "today" yields a later window — proving we don't freeze the fixed dates
  /// that the preset referred to when it was picked.
  @Test func relativePreset_reresolvesAgainstToday() {
    let earlier = Date(timeIntervalSinceReferenceDate: 700_000_000)
    let later = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let token = ReportsPeriodStorage.token(for: .last3Months)

    let seedEarlier = ReportsPeriodStorage.seed(
      storedRangeToken: token, storedCustomFrom: nil, storedCustomTo: nil, today: earlier)
    let seedLater = ReportsPeriodStorage.seed(
      storedRangeToken: token, storedCustomFrom: nil, storedCustomTo: nil, today: later)

    #expect(seedEarlier.dateRange == .last3Months)
    #expect(seedLater.dateRange == .last3Months)
    #expect(seedEarlier.resolvedFrom != seedLater.resolvedFrom)
    #expect(seedEarlier.resolvedTo != seedLater.resolvedTo)
  }

  @Test func customRange_restoresStoredEndpoints() {
    let from = Date(timeIntervalSinceReferenceDate: 100_000_000)
    let to = Date(timeIntervalSinceReferenceDate: 200_000_000)

    let seed = ReportsPeriodStorage.seed(
      storedRangeToken: ReportsPeriodStorage.token(for: .custom),
      storedCustomFrom: from.timeIntervalSinceReferenceDate,
      storedCustomTo: to.timeIntervalSinceReferenceDate,
      today: referenceToday)

    #expect(seed.dateRange == .custom)
    #expect(seed.customFrom == from)
    #expect(seed.customTo == to)
    #expect(seed.resolvedFrom == from)
    #expect(seed.resolvedTo == to)
  }

  @Test func customRange_withoutStoredDates_fallsBackToDefaults() throws {
    let seed = ReportsPeriodStorage.seed(
      storedRangeToken: ReportsPeriodStorage.token(for: .custom),
      storedCustomFrom: nil, storedCustomTo: nil, today: referenceToday)

    let expectedFrom = try #require(
      Calendar.current.date(byAdding: .year, value: -1, to: referenceToday))
    #expect(seed.customFrom == expectedFrom)
    #expect(seed.customTo == referenceToday)
    #expect(seed.resolvedFrom == expectedFrom)
    #expect(seed.resolvedTo == referenceToday)
  }

  // MARK: - Write round-trips

  @Test func persistCustomRange_roundTripsThroughDefaults() throws {
    let defaults = try #require(
      UserDefaults(suiteName: "reports-period-test-\(UUID().uuidString)"))
    let from = Date(timeIntervalSinceReferenceDate: 123_456_789)
    let to = Date(timeIntervalSinceReferenceDate: 223_456_789)

    ReportsPeriodStorage.persist(range: .custom, in: defaults)
    ReportsPeriodStorage.persistCustomFrom(from, in: defaults)
    ReportsPeriodStorage.persistCustomTo(to, in: defaults)

    let seed = ReportsPeriodStorage.seed(from: defaults, today: referenceToday)
    #expect(seed.dateRange == .custom)
    #expect(seed.customFrom == from)
    #expect(seed.customTo == to)
    #expect(seed.resolvedFrom == from)
    #expect(seed.resolvedTo == to)
  }

  @Test func persistRelativePreset_roundTripsAsPreset() throws {
    let defaults = try #require(
      UserDefaults(suiteName: "reports-period-test-\(UUID().uuidString)"))

    ReportsPeriodStorage.persist(range: .last3Months, in: defaults)

    #expect(
      ReportsPeriodStorage.seed(from: defaults, today: referenceToday).dateRange == .last3Months)
  }
}

// swiftlint:enable attributes
