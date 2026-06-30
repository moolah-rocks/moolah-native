import Foundation
import Testing

@testable import Moolah

/// Account-group (multi-account filter) prior-balance behaviour, kept in its
/// own suite so `TransactionRepositoryPriorBalanceTests` stays within the
/// `type_body_length` budget.
@Suite("TransactionRepository — group priorBalance")
struct TransactionGroupPriorBalanceTests {
  @Test("account-group priorBalance sums member legs across the group, not zero")
  func testGroupPriorBalanceAcrossMembers() async throws {
    // Two member accounts + one non-member, all in the profile instrument so
    // no conversion is needed. Before the fix a group (multi-account) filter
    // forced priorBalance to zero; it must now sum the member legs of older
    // transactions — and exclude legs in non-member accounts (e.g. the far
    // side of a transfer out of the group).
    let target = Instrument.defaultTestInstrument
    let memberA = UUID()
    let memberB = UUID()
    let nonMember = UUID()
    let (backend, database) = try TestBackend.create(instrument: target)
    TestBackend.seed(
      accounts: [
        (
          Account(id: memberA, name: "A", type: .bank, instrument: target),
          .zero(instrument: target)
        ),
        (
          Account(id: memberB, name: "B", type: .bank, instrument: target),
          .zero(instrument: target)
        ),
        (
          Account(id: nonMember, name: "C", type: .bank, instrument: target),
          .zero(instrument: target)
        ),
      ],
      in: database)

    // Oldest → newest by date. The transfer's non-member leg (+40) must be
    // excluded from the group subtotal; only memberA's -40 leg counts.
    let tx1 = Transaction(
      date: Date(timeIntervalSince1970: 1),
      payee: "A in",
      legs: [TransactionLeg(accountId: memberA, instrument: target, quantity: 50, type: .income)])
    let tx2 = Transaction(
      date: Date(timeIntervalSince1970: 2),
      payee: "B in",
      legs: [TransactionLeg(accountId: memberB, instrument: target, quantity: 30, type: .income)])
    let txTransfer = Transaction(
      date: Date(timeIntervalSince1970: 3),
      payee: "Out of group",
      legs: [
        TransactionLeg(accountId: memberA, instrument: target, quantity: -40, type: .transfer),
        TransactionLeg(accountId: nonMember, instrument: target, quantity: 40, type: .transfer),
      ])
    let tx3 = Transaction(
      date: Date(timeIntervalSince1970: 4),
      payee: "Newest",
      legs: [TransactionLeg(accountId: memberA, instrument: target, quantity: 5, type: .income)])
    TestBackend.seed(transactions: [tx1, tx2, txTransfer, tx3], in: database)

    // Group filter; pageSize 1 → page 0 is just tx3, so priorBalance covers
    // tx1 + tx2 + txTransfer's member leg = 50 + 30 + (-40) = 40.
    let groupFilter = TransactionFilter(accountIds: [memberA, memberB])
    let page0 = try await backend.transactions.fetch(
      filter: groupFilter, page: 0, pageSize: 1)

    #expect(page0.targetInstrument == target)
    let prior = try #require(page0.priorBalance)
    #expect(prior == InstrumentAmount(quantity: 40, instrument: target))
  }
}
