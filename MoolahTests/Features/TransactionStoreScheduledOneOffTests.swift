import Foundation
import Testing

@testable import Moolah

/// End-to-end coverage for the "new scheduled transaction that doesn't repeat"
/// flow: the user creates a scheduled transaction from the Upcoming view, opens
/// the inspector, and turns off the Repeat toggle. The saved transaction must
/// stay scheduled (appear in the Upcoming view) and must not leak into the
/// regular account transactions list.
@Suite("TransactionStore/ScheduledOneOff")
@MainActor
struct TransactionStoreScheduledOneOffTests {
  @Test
  func schedulingSurvivesTurningOffRepeat() async throws {
    let accountId = UUID()
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Everyday", type: .bank,
          instrument: Instrument.defaultTestInstrument)
      ],
      in: database)

    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument
    )

    // Simulates the user tapping "+" in the Upcoming view: a placeholder
    // scheduled transaction is created. The default does not repeat — it's a
    // single scheduled occurrence (`.once`).
    let created = try #require(
      await store.createDefaultScheduled(
        accountId: accountId,
        fallbackAccountId: nil,
        instrument: Instrument.defaultTestInstrument))
    #expect(created.isScheduled == true)
    #expect(created.isRecurring == false)

    // Simulates the user opening the inspector, turning Repeat on (so the
    // transaction becomes recurring) and then off again, saving the update.
    // The round-trip must leave the transaction scheduled and one-off.
    var draft = TransactionDraft(from: created)
    draft.isRepeating = true
    #expect(draft.recurPeriod == .month)
    draft.isRepeating = false
    let updated = try #require(
      draft.toTransaction(id: created.id))
    await store.update(updated)

    // The persisted transaction stays scheduled (period demoted to .once)
    // and remains visible in the scheduled filter — not the regular one.
    let scheduledPage = try await backend.transactions.fetch(
      filter: TransactionFilter(scheduled: .scheduledOnly), page: 0, pageSize: 50)
    #expect(scheduledPage.transactions.count == 1)
    let persisted = try #require(scheduledPage.transactions.first)
    #expect(persisted.id == created.id)
    #expect(persisted.recurPeriod == .once)
    #expect(persisted.isScheduled == true)
    #expect(persisted.isRecurring == false)

    let regularPage = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: accountId, scheduled: .nonScheduledOnly),
      page: 0,
      pageSize: 50)
    #expect(regularPage.transactions.isEmpty)
  }
}
