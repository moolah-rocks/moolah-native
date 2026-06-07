import Foundation
import Testing

@testable import Moolah

@Suite("AutomationService Legs — add & update")
@MainActor
struct AutomationServiceLegsTests {

  // MARK: - addLeg

  @Test("addLeg appends a leg with the requested account, type and amount")
  func addLegAppends() async throws {
    let (service, session) = try await AutomationTestSession.make()
    let checking = try await service.createAccount(
      profileIdentifier: "Test", name: "Checking", type: .bank)
    let savings = try await service.createAccount(
      profileIdentifier: "Test", name: "Savings", type: .bank)

    let txn = try await LegTestSupport.makeSingleLeg(
      session: session, accountId: checking.id, quantity: -100, payee: "Move")

    let updated = try await service.addLeg(
      profileIdentifier: "Test",
      transactionId: txn.id,
      draft: AutomationService.LegDraft(
        accountName: "Savings", amount: 100, type: "transfer"))

    #expect(updated.legs.count == 2)
    let added = try #require(updated.legs.first { $0.accountId == savings.id })
    #expect(added.type == .transfer)
    #expect(added.quantity == 100)
    #expect(added.instrument == session.profile.instrument)

    let persisted = try await LegTestSupport.fetchById(session, txn.id)
    #expect(persisted.legs.count == 2)
  }

  @Test("addLeg preserves an existing leg's externalId on the persisted txn")
  func addLegPreservesExternalId() async throws {
    let (service, session) = try await AutomationTestSession.make()
    let exchange = try await service.createAccount(
      profileIdentifier: "Test", name: "Exchange", type: .exchange)
    let bank = try await service.createAccount(
      profileIdentifier: "Test", name: "Bank", type: .bank)

    let txn = try await LegTestSupport.makeSingleLeg(
      session: session, accountId: exchange.id, quantity: 250, payee: "Deposit",
      externalId: "chain-tx-hash-abc")

    let updated = try await service.addLeg(
      profileIdentifier: "Test",
      transactionId: txn.id,
      draft: AutomationService.LegDraft(
        accountName: "Bank", amount: -250, type: "transfer"))

    // The original synced leg kept its externalId on the returned txn …
    #expect(updated.legs.contains { $0.externalId == "chain-tx-hash-abc" })

    // … and on the authoritative persisted snapshot (the whole point).
    let persisted = try await LegTestSupport.fetchById(session, txn.id)
    let preserved = persisted.legs.first { $0.externalId == "chain-tx-hash-abc" }
    #expect(preserved != nil)
    #expect(preserved?.accountId == exchange.id)
    #expect(persisted.legs.contains { $0.accountId == bank.id })
  }

  @Test("addLeg with a fiat instrument id resolves it")
  func addLegResolvesFiatInstrument() async throws {
    let (service, session) = try await AutomationTestSession.make()
    let cash = try await service.createAccount(
      profileIdentifier: "Test", name: "Cash", type: .bank)
    let usdAcct = try await service.createAccount(
      profileIdentifier: "Test", name: "USD", type: .bank)

    let txn = try await LegTestSupport.makeSingleLeg(
      session: session, accountId: cash.id, quantity: -100, payee: "FX")

    let updated = try await service.addLeg(
      profileIdentifier: "Test",
      transactionId: txn.id,
      draft: AutomationService.LegDraft(
        accountName: "USD", instrumentId: "USD", amount: 65, type: "transfer"))

    let added = try #require(updated.legs.first { $0.accountId == usdAcct.id })
    #expect(added.instrument == Instrument.fiat(code: "USD"))
  }

  @Test("addLeg with a registered crypto instrument id resolves it")
  func addLegResolvesCryptoInstrument() async throws {
    let (service, session) = try await AutomationTestSession.make()
    let usdc = try await LegTestSupport.registerUSDC(session: session)

    let wallet = try await service.createAccount(
      profileIdentifier: "Test", name: "Wallet", type: .bank)
    let bank = try await service.createAccount(
      profileIdentifier: "Test", name: "Bank", type: .bank)
    let txn = try await LegTestSupport.makeSingleLeg(
      session: session, accountId: bank.id, quantity: -100, payee: "Buy")

    let updated = try await service.addLeg(
      profileIdentifier: "Test",
      transactionId: txn.id,
      draft: AutomationService.LegDraft(
        accountName: "Wallet", instrumentId: usdc.id, amount: 100, type: "trade"))

    let added = try #require(updated.legs.first { $0.accountId == wallet.id })
    #expect(added.instrument == usdc)
    #expect(added.type == .trade)
  }

  @Test("addLeg throws for an unknown instrument id")
  func addLegUnknownInstrumentThrows() async throws {
    let (service, session) = try await AutomationTestSession.make()
    let bank = try await service.createAccount(
      profileIdentifier: "Test", name: "Bank", type: .bank)
    let txn = try await LegTestSupport.makeSingleLeg(
      session: session, accountId: bank.id, quantity: -100, payee: "X")

    await #expect(throws: AutomationError.self) {
      _ = try await service.addLeg(
        profileIdentifier: "Test",
        transactionId: txn.id,
        draft: AutomationService.LegDraft(
          accountName: "Bank", instrumentId: "99:0xdeadbeef", amount: 1, type: "trade"))
    }
  }

  @Test("addLeg throws for a missing transaction id")
  func addLegMissingTxnThrows() async throws {
    let (service, _) = try await AutomationTestSession.make()
    _ = try await service.createAccount(
      profileIdentifier: "Test", name: "Bank", type: .bank)

    await #expect(throws: AutomationError.self) {
      _ = try await service.addLeg(
        profileIdentifier: "Test",
        transactionId: UUID(),
        draft: AutomationService.LegDraft(
          accountName: "Bank", amount: 1, type: "transfer"))
    }
  }

  // MARK: - updateLeg

  @Test("updateLeg retypes a leg while preserving its externalId")
  func updateLegPreservesExternalId() async throws {
    let (service, session) = try await AutomationTestSession.make()
    let exchange = try await service.createAccount(
      profileIdentifier: "Test", name: "Exchange", type: .exchange)

    let txn = try await LegTestSupport.makeSingleLeg(
      session: session, accountId: exchange.id, quantity: 250, payee: "Deposit",
      externalId: "chain-tx-hash-xyz")
    let legId = try #require(txn.legs.first).id

    let updated = try await service.updateLeg(
      profileIdentifier: "Test",
      legId: legId,
      changes: AutomationService.LegChanges(type: "transfer"))

    let leg = try #require(updated.legs.first { $0.id == legId })
    #expect(leg.type == .transfer)
    #expect(leg.externalId == "chain-tx-hash-xyz")
    #expect(leg.quantity == 250)

    let persisted = try await LegTestSupport.fetchById(session, txn.id)
    let persistedLeg = try #require(persisted.legs.first { $0.id == legId })
    #expect(persistedLeg.type == .transfer)
    #expect(persistedLeg.externalId == "chain-tx-hash-xyz")
  }

  @Test("updateLeg changes amount and account while keeping other fields")
  func updateLegChangesAmountAndAccount() async throws {
    let (service, session) = try await AutomationTestSession.make()
    let first = try await service.createAccount(
      profileIdentifier: "Test", name: "First", type: .bank)
    let second = try await service.createAccount(
      profileIdentifier: "Test", name: "Second", type: .bank)

    let txn = try await LegTestSupport.makeSingleLeg(
      session: session, accountId: first.id, quantity: -100, payee: "Edit")
    let legId = try #require(txn.legs.first).id

    let updated = try await service.updateLeg(
      profileIdentifier: "Test",
      legId: legId,
      changes: AutomationService.LegChanges(accountName: "Second", amount: -42))

    let leg = try #require(updated.legs.first { $0.id == legId })
    #expect(leg.accountId == second.id)
    #expect(leg.quantity == -42)
    #expect(leg.type == .expense)
  }

  @Test("updateLeg throws for a missing leg id")
  func updateLegMissingThrows() async throws {
    let (service, session) = try await AutomationTestSession.make()
    let bank = try await service.createAccount(
      profileIdentifier: "Test", name: "Bank", type: .bank)
    _ = try await LegTestSupport.makeSingleLeg(
      session: session, accountId: bank.id, quantity: -100, payee: "X")

    await #expect(throws: AutomationError.self) {
      _ = try await service.updateLeg(
        profileIdentifier: "Test",
        legId: UUID(),
        changes: AutomationService.LegChanges(type: "transfer"))
    }
  }
}
