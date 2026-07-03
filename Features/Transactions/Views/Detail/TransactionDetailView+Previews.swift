import SwiftUI

@MainActor
private func previewStore() -> TransactionStore {
  let backend = PreviewBackend.create()
  return TransactionStore(
    repository: backend.transactions,
    conversionService: backend.conversionService,
    targetInstrument: .AUD
  )
}

#Preview {
  let accountId = UUID()
  return NavigationStack {
    TransactionDetailView(
      transaction: Transaction(
        date: Date(),
        payee: "Woolworths",
        legs: [
          TransactionLeg(accountId: accountId, instrument: .AUD, quantity: -50.23, type: .expense)
        ]
      ),
      accounts: Accounts(from: [
        Account(id: accountId, name: "Checking", type: .bank, instrument: .AUD),
        Account(name: "Savings", type: .bank, instrument: .AUD),
      ]),
      categories: Categories(from: [
        Category(name: "Groceries"),
        Category(name: "Transport"),
      ]),
      earmarks: Earmarks(from: [Earmark(name: "Holiday Fund", instrument: .AUD)]),
      transactionStore: previewStore(),
      viewingAccountId: accountId,

      onUpdate: { _ in },
      onDelete: { _ in }
    )
  }
}

private func customTransaction(accountId1: UUID, accountId2: UUID) -> Transaction {
  Transaction(
    date: Date(),
    payee: "Split Purchase",
    legs: [
      TransactionLeg(
        accountId: accountId1,
        instrument: .AUD,
        quantity: -30.00,
        type: .expense,
        categoryId: nil),
      TransactionLeg(
        accountId: accountId2,
        instrument: .AUD,
        quantity: -20.00,
        type: .expense,
        categoryId: nil),
    ]
  )
}

#Preview("Custom Transaction") {
  let accountId1 = UUID()
  let accountId2 = UUID()
  return NavigationStack {
    TransactionDetailView(
      transaction: customTransaction(accountId1: accountId1, accountId2: accountId2),
      accounts: Accounts(from: [
        Account(id: accountId1, name: "Checking", type: .bank, instrument: .AUD),
        Account(id: accountId2, name: "Credit Card", type: .creditCard, instrument: .AUD),
      ]),
      categories: Categories(from: [
        Category(name: "Groceries"), Category(name: "Transport"),
      ]),
      earmarks: Earmarks(from: [Earmark(name: "Holiday Fund", instrument: .AUD)]),
      transactionStore: previewStore(),

      onUpdate: { _ in },
      onDelete: { _ in }
    )
  }
}

#Preview("Earmark-Only Transaction") {
  let earmarkId = UUID()
  return NavigationStack {
    TransactionDetailView(
      transaction: Transaction(
        date: Date(),
        legs: [
          TransactionLeg(
            accountId: nil,
            instrument: .AUD,
            quantity: 500,
            type: .income,
            earmarkId: earmarkId)
        ]
      ),
      accounts: Accounts(from: [
        Account(name: "Checking", type: .bank, instrument: .AUD),
        Account(name: "Savings", type: .bank, instrument: .AUD),
      ]),
      categories: Categories(from: []),
      earmarks: Earmarks(from: [
        Earmark(id: earmarkId, name: "Income Tax FY2025", instrument: .AUD),
        Earmark(name: "Holiday Fund", instrument: .AUD),
      ]),
      transactionStore: previewStore(),

      onUpdate: { _ in },
      onDelete: { _ in }
    )
  }
}

#Preview("Cross-Currency Transfer") {
  let accountId1 = UUID()
  let accountId2 = UUID()
  return NavigationStack {
    TransactionDetailView(
      transaction: Transaction(
        date: Date(),
        payee: "Currency Exchange",
        legs: [
          TransactionLeg(accountId: accountId1, instrument: .USD, quantity: -100, type: .transfer),
          TransactionLeg(accountId: accountId2, instrument: .AUD, quantity: 155, type: .transfer),
        ]
      ),
      accounts: Accounts(from: [
        Account(id: accountId1, name: "US Checking", type: .bank, instrument: .USD),
        Account(id: accountId2, name: "AU Savings", type: .bank, instrument: .AUD),
        Account(name: "Credit Card", type: .creditCard, instrument: .USD),
      ]),
      categories: Categories(from: []),
      earmarks: Earmarks(from: []),
      transactionStore: previewStore(),
      viewingAccountId: accountId1,

      onUpdate: { _ in },
      onDelete: { _ in }
    )
  }
}

#Preview("Cross-Currency Transfer (Sent)") {
  let accountId1 = UUID()
  let accountId2 = UUID()
  return NavigationStack {
    TransactionDetailView(
      transaction: Transaction(
        date: Date(),
        payee: "Currency Exchange",
        legs: [
          TransactionLeg(accountId: accountId1, instrument: .USD, quantity: -100, type: .transfer),
          TransactionLeg(accountId: accountId2, instrument: .AUD, quantity: 155, type: .transfer),
        ]
      ),
      accounts: Accounts(from: [
        Account(id: accountId1, name: "US Checking", type: .bank, instrument: .USD),
        Account(id: accountId2, name: "AU Savings", type: .bank, instrument: .AUD),
      ]),
      categories: Categories(from: []),
      earmarks: Earmarks(from: []),
      transactionStore: previewStore(),
      viewingAccountId: accountId2,

      onUpdate: { _ in },
      onDelete: { _ in }
    )
  }
}

#Preview("Trade") {
  let accountId = UUID()
  let vgs = Instrument.stock(ticker: "VGS.AX", exchange: "ASX", name: "VGS")
  return NavigationStack {
    TransactionDetailView(
      transaction: Transaction(
        date: Date(),
        payee: "SelfWealth",
        legs: [
          TransactionLeg(accountId: accountId, instrument: .AUD, quantity: -300, type: .trade),
          TransactionLeg(accountId: accountId, instrument: vgs, quantity: 20, type: .trade),
          TransactionLeg(accountId: accountId, instrument: .AUD, quantity: -10, type: .expense),
        ]
      ),
      accounts: Accounts(from: [
        Account(id: accountId, name: "Brokerage", type: .bank, instrument: .AUD)
      ]),
      categories: Categories(from: [Category(name: "Brokerage")]),
      earmarks: Earmarks(from: []),
      transactionStore: previewStore(),
      viewingAccountId: accountId,

      onUpdate: { _ in },
      onDelete: { _ in }
    )
  }
}

#Preview("Trade (No Fee)") {
  let accountId = UUID()
  let vgs = Instrument.stock(ticker: "VGS.AX", exchange: "ASX", name: "VGS")
  return NavigationStack {
    TransactionDetailView(
      transaction: Transaction(
        date: Date(),
        legs: [
          TransactionLeg(accountId: accountId, instrument: .AUD, quantity: -300, type: .trade),
          TransactionLeg(accountId: accountId, instrument: vgs, quantity: 20, type: .trade),
        ]
      ),
      accounts: Accounts(from: [
        Account(id: accountId, name: "Brokerage", type: .bank, instrument: .AUD)
      ]),
      categories: Categories(from: []),
      earmarks: Earmarks(from: []),
      transactionStore: previewStore(),
      viewingAccountId: accountId,

      onUpdate: { _ in },
      onDelete: { _ in }
    )
  }
}

private func syncOrigin(_ source: BackgroundSyncSource) -> ImportOrigin {
  ImportOrigin(
    rawDescription: "",
    rawAmount: 0,
    importedAt: Date(),
    importSessionId: UUID(),
    parserIdentifier: source.parserIdentifier)
}

#Preview("Synced (Coinstash)") {
  let accountId = UUID()
  let eth = Instrument.crypto(
    chainId: 1, contractAddress: "0xeth", symbol: "ETH", name: "Ether", decimals: 18)
  return NavigationStack {
    TransactionDetailView(
      transaction: Transaction(
        date: Date(),
        payee: "Coinstash",
        legs: [
          TransactionLeg(
            accountId: accountId,
            instrument: eth,
            quantity: 0.5,
            externalId: "order-1",
            type: .income)
        ],
        importOrigin: .single(syncOrigin(.coinstash))
      ),
      accounts: Accounts(from: [
        Account(id: accountId, name: "Coinstash", type: .bank, instrument: eth)
      ]),
      categories: Categories(from: []),
      earmarks: Earmarks(from: []),
      transactionStore: previewStore(),
      viewingAccountId: accountId,

      onUpdate: { _ in },
      onDelete: { _ in }
    )
  }
}

private func syncedWalletTransaction(
  accountId1: UUID, accountId2: UUID, eth: Instrument
) -> Transaction {
  Transaction(
    date: Date(),
    payee: "On-chain activity",
    legs: [
      // Synced leg — carries the on-chain externalId, gets the header icon.
      TransactionLeg(
        accountId: accountId1,
        instrument: eth,
        quantity: -0.3,
        externalId: "0xhash:0",
        type: .expense),
      // Manually-added leg — no externalId, so no indicator.
      TransactionLeg(accountId: accountId2, instrument: eth, quantity: -0.2, type: .expense),
    ],
    importOrigin: .single(syncOrigin(.wallet)))
}

#Preview("Custom (Synced Wallet + Manual Leg)") {
  let accountId1 = UUID()
  let accountId2 = UUID()
  let eth = Instrument.crypto(
    chainId: 1, contractAddress: "0xeth", symbol: "ETH", name: "Ether", decimals: 18)
  return NavigationStack {
    TransactionDetailView(
      transaction: syncedWalletTransaction(
        accountId1: accountId1, accountId2: accountId2, eth: eth),
      accounts: Accounts(from: [
        Account(id: accountId1, name: "Wallet", type: .bank, instrument: eth),
        Account(id: accountId2, name: "Cold Storage", type: .bank, instrument: eth),
      ]),
      categories: Categories(from: []),
      earmarks: Earmarks(from: []),
      transactionStore: previewStore(),
      viewingAccountId: accountId1,

      onUpdate: { _ in },
      onDelete: { _ in }
    )
  }
}

#Preview("Scheduled (Recurring)") {
  let accountId = UUID()
  return NavigationStack {
    TransactionDetailView(
      transaction: Transaction(
        date: Date().addingTimeInterval(60 * 60 * 24 * 3),
        payee: "Rent",
        recurPeriod: .month,
        recurEvery: 1,
        legs: [
          TransactionLeg(accountId: accountId, instrument: .AUD, quantity: -1800, type: .expense)
        ]
      ),
      accounts: Accounts(from: [
        Account(id: accountId, name: "Checking", type: .bank, instrument: .AUD)
      ]),
      categories: Categories(from: [Category(name: "Housing")]),
      earmarks: Earmarks(from: []),
      transactionStore: previewStore(),
      showRecurrence: true,
      viewingAccountId: accountId,

      onUpdate: { _ in },
      onDelete: { _ in }
    )
  }
}
