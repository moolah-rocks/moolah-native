import Foundation
import Testing

@testable import Moolah

@Suite("AccountCashFlows.flowAmounts(for:)")
struct AccountCashFlowsTests {
  let aud = Instrument.AUD
  let usd = Instrument.USD
  let accountId = UUID()
  let otherAccountId = UUID()

  /// Day 0 = 2026-03-15. `days` may exceed month length; calendar
  /// arithmetic rolls over correctly.
  private func date(daysAfterEpoch days: Int, hour: Int = 0) throws -> Date {
    let calendar = Calendar(identifier: .gregorian)
    var epoch = DateComponents()
    epoch.year = 2026
    epoch.month = 3
    epoch.day = 15
    epoch.hour = hour
    let base = try #require(calendar.date(from: epoch))
    return try #require(calendar.date(byAdding: .day, value: days, to: base))
  }

  // MARK: - Opening balance leg counts as a flow

  @Test("openingBalance leg in host currency returns one amount equal to the leg quantity")
  func openingBalanceHostCurrencyLeg() async throws {
    let txn = Transaction(
      date: try date(daysAfterEpoch: 0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: 1_000, type: .openingBalance
        )
      ]
    )
    let service = FakeConversionService.fixedRates([:])
    let amounts = try await AccountCashFlows.flowAmounts(
      for: txn, accountId: accountId, hostCurrency: aud, service: service
    )
    #expect(amounts == [1_000])
  }

  @Test("openingBalance leg in foreign currency converts on transaction.date")
  func openingBalanceForeignCurrencyLegUsesTxnDate() async throws {
    // Two distinct rates on different days — locks in the date choice.
    let day0 = try date(daysAfterEpoch: 0)
    let day10 = try date(daysAfterEpoch: 10)
    let day0Rate = try #require(Decimal(string: "1.50"))
    let day10Rate = try #require(Decimal(string: "1.40"))
    let service = FakeConversionService.dateRates([
      day0: [usd.id: day0Rate],
      day10: [usd.id: day10Rate],
    ])
    let txn = Transaction(
      date: try date(daysAfterEpoch: 0, hour: 14),  // non-zero clock time
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: usd, quantity: 100, type: .openingBalance
        )
      ]
    )
    let amounts = try await AccountCashFlows.flowAmounts(
      for: txn, accountId: accountId, hostCurrency: aud, service: service
    )
    #expect(amounts == [Decimal(150)])  // 100 × 1.50, the day-0 rate
  }

  // MARK: - Boundary-crossing transactions

  @Test("boundary-crossing host-currency leg returns the leg quantity (Rule 8 fast path)")
  func boundaryCrossingHostCurrencyLegFastPath() async throws {
    // FakeConversionService.perCall: callCount counts every convert(...) call;
    // the helper hits the fast path for host-currency legs and never calls
    // through, so callCount must remain zero. The outcome closure returning
    // .success(0) is intentionally wrong-shaped — if the fast path regresses
    // and convert(...) is invoked, the assertion `amounts == [250]` will
    // fail (amounts would be `[0]`), pinpointing the regression.
    let counter = FakeConversionService.perCall { _ in .success(0) }
    let txn = Transaction(
      date: try date(daysAfterEpoch: 1),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: 250, type: .income
        ),
        TransactionLeg(
          accountId: otherAccountId, instrument: aud, quantity: -250, type: .expense
        ),
      ]
    )
    let amounts = try await AccountCashFlows.flowAmounts(
      for: txn, accountId: accountId, hostCurrency: aud, service: counter
    )
    #expect(amounts == [250])
    #expect(counter.callCount == 0)
  }

  @Test("boundary-crossing foreign-currency leg converts on transaction.date")
  func boundaryCrossingForeignCurrencyLeg() async throws {
    let day0 = try date(daysAfterEpoch: 0)
    let day5 = try date(daysAfterEpoch: 5)
    let day0Rate = try #require(Decimal(string: "1.50"))
    let day5Rate = try #require(Decimal(string: "1.40"))
    let service = FakeConversionService.dateRates([
      day0: [usd.id: day0Rate],
      day5: [usd.id: day5Rate],
    ])
    let txn = Transaction(
      date: try date(daysAfterEpoch: 0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: usd, quantity: 100, type: .income
        ),
        TransactionLeg(
          accountId: otherAccountId, instrument: usd, quantity: -100, type: .expense
        ),
      ]
    )
    let amounts = try await AccountCashFlows.flowAmounts(
      for: txn, accountId: accountId, hostCurrency: aud, service: service
    )
    #expect(amounts == [Decimal(150)])  // 100 × 1.50, day-0 rate
  }

  // MARK: - Intra-account transactions skip flow extraction

  @Test("intra-account-only transaction returns []")
  func intraAccountTransactionReturnsEmpty() async throws {
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let txn = Transaction(
      date: try date(daysAfterEpoch: 1),
      legs: [
        TransactionLeg(accountId: accountId, instrument: bhp, quantity: 100, type: .trade),
        TransactionLeg(accountId: accountId, instrument: aud, quantity: -4_000, type: .trade),
      ]
    )
    let service = FakeConversionService.fixedRates([:])
    let amounts = try await AccountCashFlows.flowAmounts(
      for: txn, accountId: accountId, hostCurrency: aud, service: service
    )
    #expect(amounts.isEmpty)
  }

  // MARK: - Multi-leg transactions return one entry per qualifying leg

  @Test("multi-leg transaction with two qualifying account legs returns two amounts in leg order")
  func multiLegOrderPreserved() async throws {
    // Two opening-balance legs in the account (atypical but legal).
    let txn = Transaction(
      date: try date(daysAfterEpoch: 0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: 100, type: .openingBalance
        ),
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: 200, type: .openingBalance
        ),
      ]
    )
    let service = FakeConversionService.fixedRates([:])
    let amounts = try await AccountCashFlows.flowAmounts(
      for: txn, accountId: accountId, hostCurrency: aud, service: service
    )
    #expect(amounts == [100, 200])
  }

  // MARK: - Conversion failure throws and stops further conversions

  @Test("conversion failure on first qualifying leg rethrows; later legs are not converted")
  func conversionFailureStopsOnFirstError() async throws {
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    // FakeConversionService.perCall: outcome closure receives the
    // 0-based call index so we can fail the first call and verify
    // subsequent calls never happen (callCount is checked below).
    let counter = FakeConversionService.perCall { _ in
      .failure(ConversionTestError.unavailable)
    }
    let txn = Transaction(
      date: try date(daysAfterEpoch: 0),
      legs: [
        TransactionLeg(accountId: accountId, instrument: usd, quantity: 100, type: .income),
        TransactionLeg(accountId: accountId, instrument: bhp, quantity: 50, type: .income),
        TransactionLeg(accountId: otherAccountId, instrument: aud, quantity: -100, type: .expense),
      ]
    )
    do {
      _ = try await AccountCashFlows.flowAmounts(
        for: txn, accountId: accountId, hostCurrency: aud, service: counter
      )
      Issue.record("Expected throw")
    } catch is ConversionTestError {
      // expected
    }
    #expect(counter.callCount == 1)  // first call threw; helper bailed
  }

  // MARK: - Cancellation propagates

  @Test("CancellationError propagates unwrapped")
  func cancellationPropagates() async throws {
    let txn = Transaction(
      date: try date(daysAfterEpoch: 0),
      legs: [
        TransactionLeg(accountId: accountId, instrument: usd, quantity: 100, type: .income),
        TransactionLeg(accountId: otherAccountId, instrument: aud, quantity: -100, type: .expense),
      ]
    )
    let service = FakeConversionService.perCall { _ in .failure(CancellationError()) }
    do {
      _ = try await AccountCashFlows.flowAmounts(
        for: txn, accountId: accountId, hostCurrency: aud, service: service
      )
      Issue.record("Expected throw")
    } catch is CancellationError {
      // expected — propagated unwrapped, not wrapped in another error.
    }
  }
}

// Local error used only in this suite.
private enum ConversionTestError: Error {
  case unavailable
}
