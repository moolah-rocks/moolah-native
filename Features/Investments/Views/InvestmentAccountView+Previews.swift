import SwiftUI

@MainActor
private func seedLegacyValuations(
  backend: any BackendProvider, account: Account, store: InvestmentStore
) async {
  _ = try? await backend.accounts.create(
    account, openingBalance: InstrumentAmount(quantity: 10_000, instrument: .AUD))
  let calendar = Calendar.current
  for monthsAgo in (0..<6).reversed() {
    let date = calendar.date(byAdding: .month, value: -monthsAgo, to: Date()) ?? Date()
    let quantity: Decimal = 9_500 + Decimal(6 - monthsAgo) * 400
    await store.setValue(
      accountId: account.id,
      date: date,
      value: InstrumentAmount(quantity: quantity, instrument: .AUD))
  }
}

@MainActor
private func seedPositionValuations(backend: any BackendProvider, account: Account) async {
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  _ = try? await backend.accounts.create(
    account, openingBalance: InstrumentAmount(quantity: 0, instrument: .AUD))
  _ = try? await backend.transactions.create(
    Transaction(
      date: Date().addingTimeInterval(-86_400 * 30),
      legs: [
        TransactionLeg(accountId: account.id, instrument: bhp, quantity: 100, type: .trade),
        TransactionLeg(accountId: account.id, instrument: .AUD, quantity: -4_000, type: .trade),
      ]))
}

#Preview {
  let backend = PreviewBackend.create()
  let investmentStore = InvestmentStore(
    repository: backend.investments,
    transactionRepository: backend.transactions,
    conversionService: backend.conversionService)
  let transactionStore = TransactionStore(
    repository: backend.transactions,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)
  // In-memory preview session can't fail in practice: opens an ephemeral
  // GRDB queue with no disk access. A trap here is acceptable in #Preview.
  // swiftlint:disable:next force_try
  let session = try! ProfileSession.preview()
  let account = Account(name: "Brokerage", type: .investment, instrument: .AUD)
  return NavigationStack {
    InvestmentAccountView(
      account: account,
      accounts: Accounts(from: [account]),
      categories: Categories(from: []),
      earmarks: Earmarks(from: []),
      investmentStore: investmentStore,
      transactionStore: transactionStore
    )
  }
  .previewProfileEnvironment(session: session)
  .frame(width: 720, height: 560)
  .task { await seedLegacyValuations(backend: backend, account: account, store: investmentStore) }
}

// `.calculatedFromTrades` investment accounts are now routed to
// `AccountDetailView` in production (ContentView+AccountDetail.swift).
// These previews mirror that routing. Extracted from `#Preview` closures so
// the verbose `AccountDetailView` wiring is governed by
// `function_body_length` rather than the stricter `closure_body_length`.

#Preview("Position-tracked") {
  positionTrackedPreview()
}

@MainActor
private func seedFullySoldPositions(backend: any BackendProvider, account: Account) async {
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  _ = try? await backend.accounts.create(
    account, openingBalance: InstrumentAmount(quantity: 0, instrument: .AUD))
  // Buy 100 BHP @ 40 AUD on day -45.
  _ = try? await backend.transactions.create(
    Transaction(
      date: Date().addingTimeInterval(-86_400 * 45),
      legs: [
        TransactionLeg(accountId: account.id, instrument: bhp, quantity: 100, type: .trade),
        TransactionLeg(accountId: account.id, instrument: .AUD, quantity: -4_000, type: .trade),
      ]))
  // Sell all 100 BHP @ 50 AUD on day -15.
  _ = try? await backend.transactions.create(
    Transaction(
      date: Date().addingTimeInterval(-86_400 * 15),
      legs: [
        TransactionLeg(accountId: account.id, instrument: bhp, quantity: -100, type: .trade),
        TransactionLeg(accountId: account.id, instrument: .AUD, quantity: 5_000, type: .trade),
      ]))
}

#Preview("Position-tracked (fully sold)") {
  positionTrackedFullySoldPreview()
}

@MainActor
private func positionTrackedPreview() -> some View {
  let backend = PreviewBackend.create()
  let transactionStore = TransactionStore(
    repository: backend.transactions,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)
  // In-memory preview session can't fail in practice: opens an ephemeral
  // GRDB queue with no disk access. A trap here is acceptable in #Preview.
  // swiftlint:disable:next force_try
  let session = try! ProfileSession.preview()
  let account = Account(
    name: "Brokerage",
    type: .investment,
    instrument: .AUD,
    valuationMode: .calculatedFromTrades)
  return NavigationStack {
    AccountDetailView(
      title: account.name,
      transactionFilter: TransactionFilter(accountId: account.id),
      positions: [],
      hostCurrency: account.instrument,
      accountIds: [account.id],
      conversionService: backend.conversionService,
      registrationsVersion: 0,
      accountChainId: nil,
      alwaysShowsFullSurface: true,
      syncedHeaderAccount: nil,
      accounts: Accounts(from: [account]),
      categories: Categories(from: []),
      earmarks: Earmarks(from: []),
      transactionStore: transactionStore
    )
  }
  .previewProfileEnvironment(session: session)
  .frame(width: 720, height: 600)
  .task { await seedPositionValuations(backend: backend, account: account) }
}

@MainActor
private func positionTrackedFullySoldPreview() -> some View {
  let backend = PreviewBackend.create()
  let transactionStore = TransactionStore(
    repository: backend.transactions,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)
  // In-memory preview session can't fail in practice: opens an ephemeral
  // GRDB queue with no disk access. A trap here is acceptable in #Preview.
  // swiftlint:disable:next force_try
  let session = try! ProfileSession.preview()
  let account = Account(
    name: "Brokerage",
    type: .investment,
    instrument: .AUD,
    valuationMode: .calculatedFromTrades)
  return NavigationStack {
    AccountDetailView(
      title: account.name,
      transactionFilter: TransactionFilter(accountId: account.id),
      positions: [],
      hostCurrency: account.instrument,
      accountIds: [account.id],
      conversionService: backend.conversionService,
      registrationsVersion: 0,
      accountChainId: nil,
      alwaysShowsFullSurface: true,
      syncedHeaderAccount: nil,
      accounts: Accounts(from: [account]),
      categories: Categories(from: []),
      earmarks: Earmarks(from: []),
      transactionStore: transactionStore
    )
  }
  .previewProfileEnvironment(session: session)
  .frame(width: 720, height: 600)
  .task { await seedFullySoldPositions(backend: backend, account: account) }
}
