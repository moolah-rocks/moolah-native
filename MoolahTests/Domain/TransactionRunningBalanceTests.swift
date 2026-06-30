import Foundation
import Testing

@testable import Moolah

@Suite("TransactionPage.withRunningBalances")
struct TransactionRunningBalanceTests {
  private let target = Instrument.defaultTestInstrument
  private let foreign = Instrument.USD

  private func date(_ days: Int) -> Date {
    guard
      let result = Calendar(identifier: .gregorian)
        .date(byAdding: .day, value: days, to: Date(timeIntervalSince1970: 0))
    else {
      preconditionFailure("Adding \(days) days to the Unix epoch must produce a valid date")
    }
    return result
  }

  private func tx(
    id: UUID = UUID(),
    daysFromEpoch: Int,
    accountId: UUID,
    quantity: Decimal,
    instrument: Instrument
  ) -> Transaction {
    Transaction(
      id: id,
      date: date(daysFromEpoch),
      payee: "Payee",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: instrument,
          quantity: quantity,
          type: .expense
        )
      ]
    )
  }

  /// All legs convert successfully — every transaction gets a valid balance.
  @Test
  func allLegsConvertibleYieldsBalancesForEveryTransaction() async {
    let accountId = UUID()
    // Target instrument differs from the default test instrument so make sure
    // we're using the ambient default.
    let transactions = [
      tx(daysFromEpoch: 3, accountId: accountId, quantity: -30, instrument: target),
      tx(daysFromEpoch: 2, accountId: accountId, quantity: -20, instrument: target),
      tx(daysFromEpoch: 1, accountId: accountId, quantity: -10, instrument: target),
    ]

    let response = await TransactionPage.withRunningBalances(
      transactions: transactions,
      priorBalance: .zero(instrument: target),
      accountId: accountId,
      targetInstrument: target,
      conversionService: FakeConversionService.fixedRates([:])
    )

    #expect(response.rows.count == 3)
    #expect(response.rows.allSatisfy { $0.balance != nil })
    #expect(response.rows.allSatisfy { $0.displayAmount != nil })
    // No conversion errors occurred.
    #expect(response.firstConversionError == nil)
  }

  /// A transaction with an unconvertible leg still appears in the result,
  /// but with a nil balance and nil displayAmount.
  @Test
  func unconvertibleTransactionStillAppearsWithNilBalance() async {
    let accountId = UUID()
    let transactions = [
      tx(daysFromEpoch: 1, accountId: accountId, quantity: -10, instrument: foreign)
    ]

    let response = await TransactionPage.withRunningBalances(
      transactions: transactions,
      priorBalance: .zero(instrument: target),
      accountId: accountId,
      targetInstrument: target,
      conversionService: FakeConversionService.failingInstruments([foreign.id])
    )

    #expect(response.rows.count == 1)
    #expect(response.rows[0].transaction.id == transactions[0].id)
    #expect(response.rows[0].balance == nil)
    #expect(response.rows[0].displayAmount == nil)
    // The error is exposed to callers so they can surface a retry path.
    #expect(response.firstConversionError != nil)
  }

  /// Earlier transactions (older — processed first in the reversed iteration)
  /// keep their balances even when a later (newer) transaction can't convert.
  /// Newer transactions after the failure point have nil balances.
  @Test
  func conversionFailureBreaksBalanceChainForLaterTransactions() async {
    let accountId = UUID()
    // Oldest first in source → in the newest-first returned list this is
    // the last entry. We list newest-first as the function expects.
    let oldestId = UUID()
    let middleId = UUID()
    let newestId = UUID()
    let transactions = [
      // newest — unconvertible
      tx(id: newestId, daysFromEpoch: 3, accountId: accountId, quantity: -30, instrument: foreign),
      // middle — convertible
      tx(id: middleId, daysFromEpoch: 2, accountId: accountId, quantity: -20, instrument: target),
      // oldest — convertible
      tx(id: oldestId, daysFromEpoch: 1, accountId: accountId, quantity: -10, instrument: target),
    ]

    let response = await TransactionPage.withRunningBalances(
      transactions: transactions,
      priorBalance: .zero(instrument: target),
      accountId: accountId,
      targetInstrument: target,
      conversionService: FakeConversionService.failingInstruments([foreign.id])
    )

    #expect(response.rows.count == 3)
    // Result is newest-first. Oldest two (middle, oldest) keep their balances.
    let byId = Dictionary(uniqueKeysWithValues: response.rows.map { ($0.transaction.id, $0) })
    #expect(byId[oldestId]?.balance != nil)
    #expect(byId[middleId]?.balance != nil)
    // The unconvertible newest transaction has nil balance.
    #expect(byId[newestId]?.balance == nil)
    #expect(byId[newestId]?.displayAmount == nil)
    // Error propagates out even though other rows convert cleanly.
    #expect(response.firstConversionError != nil)
  }

  /// When the FIRST (oldest) transaction can't convert, every subsequent
  /// (newer) transaction has nil balance — the running total is unrecoverable.
  @Test
  func conversionFailureAtOldestBreaksAllBalances() async {
    let accountId = UUID()
    let oldestId = UUID()
    let middleId = UUID()
    let newestId = UUID()
    let transactions = [
      tx(id: newestId, daysFromEpoch: 3, accountId: accountId, quantity: -30, instrument: target),
      tx(id: middleId, daysFromEpoch: 2, accountId: accountId, quantity: -20, instrument: target),
      tx(id: oldestId, daysFromEpoch: 1, accountId: accountId, quantity: -10, instrument: foreign),
    ]

    let response = await TransactionPage.withRunningBalances(
      transactions: transactions,
      priorBalance: .zero(instrument: target),
      accountId: accountId,
      targetInstrument: target,
      conversionService: FakeConversionService.failingInstruments([foreign.id])
    )

    #expect(response.rows.count == 3)
    #expect(response.rows.allSatisfy { $0.balance == nil })
    #expect(response.firstConversionError != nil)
  }

  /// Issue #48: conversion failures must be reported to the caller — no more
  /// silent `try?`-style swallow. Captures the first error encountered so a
  /// store can surface it to the user and log/diagnose in production.
  @Test
  func conversionFailureReportsFirstError() async throws {
    let accountId = UUID()
    // Oldest fails first so it's the "first" error in chronological processing.
    let oldestFailingId = UUID()
    let newerFailingId = UUID()
    let transactions = [
      tx(
        id: newerFailingId, daysFromEpoch: 3, accountId: accountId,
        quantity: -30, instrument: foreign),
      tx(
        id: oldestFailingId, daysFromEpoch: 2, accountId: accountId,
        quantity: -20, instrument: foreign),
    ]

    let response = await TransactionPage.withRunningBalances(
      transactions: transactions,
      priorBalance: .zero(instrument: target),
      accountId: accountId,
      targetInstrument: target,
      conversionService: FakeConversionService.failingInstruments([foreign.id])
    )

    let error = try #require(response.firstConversionError)
    // Processing iterates oldest-to-newest (reversed), so the first failure
    // recorded is the oldest transaction.
    #expect(error.transactionId == oldestFailingId)
    #expect(error.targetInstrumentId == target.id)
  }

  // MARK: - Account-group scoping (member-account set)

  /// Viewing an account *group*'s combined transactions, the running balance
  /// must sum only the legs belonging to member accounts — a leg in a
  /// non-member account contributes zero, exactly as the single-account path
  /// scopes to its one account. Regression for the group-balance bug where
  /// the merged list summed every leg (and so never tied out to the group's
  /// sidebar total).
  @Test
  func accountGroupScopesRunningBalanceToMemberAccounts() async {
    let memberA = UUID()
    let memberB = UUID()
    let nonMember = UUID()
    let nonMemberId = UUID()
    // newest-first, as the function expects.
    let transactions = [
      tx(daysFromEpoch: 4, accountId: memberA, quantity: -5, instrument: target),
      tx(
        id: nonMemberId, daysFromEpoch: 3, accountId: nonMember, quantity: -100, instrument: target),
      tx(daysFromEpoch: 2, accountId: memberB, quantity: -20, instrument: target),
      tx(daysFromEpoch: 1, accountId: memberA, quantity: -10, instrument: target),
    ]

    let response = await TransactionPage.withRunningBalances(
      transactions: transactions,
      priorBalance: .zero(instrument: target),
      accountId: nil,
      accountIds: [memberA, memberB],
      targetInstrument: target,
      conversionService: FakeConversionService.fixedRates([:])
    )

    #expect(response.firstConversionError == nil)
    // Newest balance = -10 (A) + -20 (B) + 0 (non-member, excluded) + -5 (A) = -35.
    // Without member scoping the non-member's -100 leaks in, giving -135.
    #expect(response.rows.first?.balance?.quantity == -35)
    // The non-member transaction contributes zero to the running balance.
    let byId = Dictionary(uniqueKeysWithValues: response.rows.map { ($0.transaction.id, $0) })
    #expect(byId[nonMemberId]?.displayAmount == .zero(instrument: target))
  }

  // MARK: - .knownZero legs (issue #790)

  /// Issue #790: a leg whose conversion resolves to `.knownZero` (an
  /// `.unpriced` / `.spam` crypto registration) contributes zero to the
  /// running balance — it does NOT mark the row unavailable. This is
  /// distinct from a transient rate-source failure, which still blanks
  /// the row and surfaces an error.
  @Test
  func knownZeroLegContributesZeroAndDoesNotBreakBalance() async {
    let accountId = UUID()
    let spam = foreign  // pretend `foreign` is the `.unpriced` / `.spam` token
    // newest → oldest. The middle leg is in the spam instrument and must
    // contribute zero rather than failing the chain.
    let transactions = [
      tx(daysFromEpoch: 3, accountId: accountId, quantity: -30, instrument: target),
      tx(daysFromEpoch: 2, accountId: accountId, quantity: -20, instrument: spam),
      tx(daysFromEpoch: 1, accountId: accountId, quantity: -10, instrument: target),
    ]

    let response = await TransactionPage.withRunningBalances(
      transactions: transactions,
      priorBalance: .zero(instrument: target),
      accountId: accountId,
      targetInstrument: target,
      conversionService: FakeConversionService.fixedRates([:], knownZero: [spam.id])
    )

    #expect(response.rows.count == 3)
    // No error surfaces — `.knownZero` is intentional, not a failure.
    #expect(response.firstConversionError == nil)
    // Every row has a balance — the spam leg folds to zero rather than
    // breaking the chain.
    #expect(response.rows.allSatisfy { $0.balance != nil })
    // Running balance accumulates only the priced contributions:
    // -10 (oldest) + 0 (spam) + -30 (newest) = -40.
    let oldestBalance = response.rows.last?.balance?.quantity
    let middleBalance = response.rows[1].balance?.quantity
    let newestBalance = response.rows.first?.balance?.quantity
    #expect(oldestBalance == -10)
    #expect(middleBalance == -10)  // spam leg contributed zero
    #expect(newestBalance == -40)
  }

  /// Issue #790: an account with a `.knownZero` source whose
  /// account-scoped display amount sits cleanly at zero in the target
  /// instrument. Per the issue's "or surface them as 'value unknown'"
  /// permission, zero-contribution is the chosen UX.
  @Test
  func knownZeroLeg_displayAmountIsZero() async {
    let accountId = UUID()
    let spam = foreign
    let transactions = [
      tx(daysFromEpoch: 1, accountId: accountId, quantity: -10, instrument: spam)
    ]

    let response = await TransactionPage.withRunningBalances(
      transactions: transactions,
      priorBalance: .zero(instrument: target),
      accountId: accountId,
      targetInstrument: target,
      conversionService: FakeConversionService.fixedRates([:], knownZero: [spam.id])
    )

    #expect(response.rows.count == 1)
    #expect(response.firstConversionError == nil)
    let row = response.rows[0]
    #expect(row.balance == .zero(instrument: target))
    #expect(row.displayAmount == .zero(instrument: target))
  }
}
