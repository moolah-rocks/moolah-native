// swiftlint:disable multiline_arguments

import SwiftUI

// File-private namespace satisfies the SwiftLint `file_name` rule which
// expects the file's name to match a top-level declaration. The extension
// is otherwise empty — the previews use file-scope helpers below.
extension TransactionRowView {}

private struct PreviewData {
  let sourceId = UUID()
  let savingsId = UUID()
  let groceriesId = UUID()
  let holidayFundId = UUID()
  let scam = Instrument.crypto(
    chainId: 1, contractAddress: "0xdeadbeef", symbol: "SCAM",
    name: "Scam Token", decimals: 18)

  var accounts: Accounts {
    Accounts(from: [
      Account(
        id: savingsId, name: "Savings", type: .bank, instrument: .AUD,
        positions: [Position(instrument: .AUD, quantity: 5000)])
    ])
  }
  var categories: Categories {
    Categories(from: [
      Category(id: groceriesId, name: "Groceries"),
      Category(name: "Transport"),
    ])
  }
  var earmarks: Earmarks {
    Earmarks(from: [
      Earmark(id: holidayFundId, name: "Holiday Fund", instrument: .AUD)
    ])
  }
}

private struct PreviewRowSpec {
  let payee: String?
  let legs: [TransactionLeg]
  let displayAmounts: [InstrumentAmount]
  let balance: Decimal
  var accountContext: UUID?
}

@MainActor
private func previewRow(
  data: PreviewData,
  id: UUID = UUID(),
  payee: String? = nil,
  legs: [TransactionLeg],
  displayAmounts: [InstrumentAmount],
  balance: Decimal,
  scopeReferenceInstrument: Instrument = .AUD,
  accountContext: UUID? = nil,
  date: Date = Date(),
  recurPeriod: RecurPeriod? = nil,
  recurEvery: Int? = nil,
  isOverdue: Bool = false,
  isDueToday: Bool = false,
  onPay: (() -> Void)? = nil,
  pendingPayId: Transaction.ID? = nil
) -> TransactionRowView {
  let transaction = Transaction(
    id: id, date: date, payee: payee ?? "",
    recurPeriod: recurPeriod, recurEvery: recurEvery,
    legs: legs)
  return TransactionRowView(
    transaction: transaction,
    accounts: data.accounts, categories: data.categories, earmarks: data.earmarks,
    displayAmounts: displayAmounts,
    balance: InstrumentAmount(quantity: balance, instrument: .AUD),
    scopeReferenceInstrument: scopeReferenceInstrument,
    accountContext: accountContext,
    isOverdue: isOverdue,
    isDueToday: isDueToday,
    onPay: onPay,
    pendingPayId: pendingPayId)
}

private func previewRowSpecs(data: PreviewData) -> [PreviewRowSpec] {
  simplePreviewSpecs(data: data) + tradePreviewSpecs(data: data)
}

private func simplePreviewSpecs(data: PreviewData) -> [PreviewRowSpec] {
  [
    PreviewRowSpec(
      payee: "Woolworths",
      legs: [
        TransactionLeg(
          accountId: data.sourceId, instrument: .AUD, quantity: -50.23, type: .expense,
          categoryId: data.groceriesId)
      ],
      displayAmounts: [InstrumentAmount(quantity: -50.23, instrument: .AUD)],
      balance: 1000),
    PreviewRowSpec(
      payee: "Employer Pty Ltd",
      legs: [
        TransactionLeg(
          accountId: data.sourceId, instrument: .AUD, quantity: 3500, type: .income,
          earmarkId: data.holidayFundId)
      ],
      displayAmounts: [InstrumentAmount(quantity: 3500, instrument: .AUD)],
      balance: 1050.23),
    PreviewRowSpec(
      payee: nil,
      legs: [
        TransactionLeg(
          accountId: data.sourceId, instrument: .AUD, quantity: -1000, type: .transfer),
        TransactionLeg(
          accountId: data.savingsId, instrument: .AUD, quantity: 1000, type: .transfer),
      ],
      displayAmounts: [InstrumentAmount(quantity: -1000, instrument: .AUD)],
      balance: -2449.77, accountContext: data.sourceId),
    PreviewRowSpec(
      payee: "Rent Split",
      legs: [
        TransactionLeg(
          accountId: data.sourceId, instrument: .AUD, quantity: -500, type: .transfer),
        TransactionLeg(
          accountId: data.savingsId, instrument: .AUD, quantity: 500, type: .transfer),
      ],
      displayAmounts: [InstrumentAmount(quantity: -500, instrument: .AUD)],
      balance: -1449.77, accountContext: data.sourceId),
  ]
}

private func tradePreviewSpecs(data: PreviewData) -> [PreviewRowSpec] {
  [
    PreviewRowSpec(
      payee: "Stock Trade",
      legs: [
        TransactionLeg(
          accountId: data.sourceId, instrument: .AUD, quantity: -1000, type: .transfer),
        TransactionLeg(
          accountId: data.savingsId, instrument: .AUD, quantity: 950, type: .transfer),
        TransactionLeg(
          accountId: data.sourceId, instrument: .AUD, quantity: -50, type: .expense),
      ],
      displayAmounts: [
        InstrumentAmount(quantity: -1000, instrument: .AUD),
        InstrumentAmount(quantity: 950, instrument: .AUD),
        InstrumentAmount(quantity: -50, instrument: .AUD),
      ],
      balance: -2499.77, accountContext: data.sourceId),
    PreviewRowSpec(
      payee: "",
      legs: [
        TransactionLeg(
          accountId: data.sourceId, instrument: .AUD, quantity: -100, type: .trade),
        TransactionLeg(
          accountId: data.sourceId, instrument: data.scam, quantity: 1_000_000, type: .trade),
      ],
      displayAmounts: [
        InstrumentAmount(quantity: -100, instrument: .AUD),
        InstrumentAmount(quantity: 1_000_000, instrument: data.scam),
      ],
      balance: -1_549.77, accountContext: data.sourceId),
  ]
}

#Preview("Standard rows") {
  let data = PreviewData()
  return List {
    ForEach(Array(previewRowSpecs(data: data).enumerated()), id: \.offset) { _, spec in
      previewRow(
        data: data, payee: spec.payee, legs: spec.legs,
        displayAmounts: spec.displayAmounts, balance: spec.balance,
        accountContext: spec.accountContext)
    }
  }
  .environment(\.spamInstruments, [data.scam])
}

@MainActor
private func overdueScheduledRow(data: PreviewData) -> TransactionRowView {
  let overdueDate = Calendar.current.date(byAdding: .day, value: -3, to: Date()) ?? Date()
  return previewRow(
    data: data, payee: "Rent",
    legs: [
      TransactionLeg(
        accountId: data.sourceId, instrument: .AUD, quantity: -2000, type: .expense)
    ],
    displayAmounts: [InstrumentAmount(quantity: -2000, instrument: .AUD)],
    balance: 1000,
    date: overdueDate,
    recurPeriod: .month, recurEvery: 1,
    isOverdue: true,
    onPay: {})
}

@MainActor
private func dueTodayScheduledRow(data: PreviewData) -> TransactionRowView {
  previewRow(
    data: data, payee: "Internet",
    legs: [
      TransactionLeg(
        accountId: data.sourceId, instrument: .AUD, quantity: -150, type: .expense)
    ],
    displayAmounts: [InstrumentAmount(quantity: -150, instrument: .AUD)],
    balance: 850,
    recurPeriod: .month, recurEvery: 1,
    isDueToday: true,
    onPay: {})
}

@MainActor
private func payAffordanceScheduledRow(data: PreviewData) -> TransactionRowView {
  previewRow(
    data: data, payee: "Phone",
    legs: [
      TransactionLeg(
        accountId: data.sourceId, instrument: .AUD, quantity: -75, type: .expense)
    ],
    displayAmounts: [InstrumentAmount(quantity: -75, instrument: .AUD)],
    balance: 775,
    recurPeriod: .month, recurEvery: 1,
    onPay: {})
}

@MainActor
private func payingScheduledRow(
  data: PreviewData, pendingId: UUID
) -> TransactionRowView {
  previewRow(
    data: data, id: pendingId, payee: "Insurance",
    legs: [
      TransactionLeg(
        accountId: data.sourceId, instrument: .AUD, quantity: -200, type: .expense)
    ],
    displayAmounts: [InstrumentAmount(quantity: -200, instrument: .AUD)],
    balance: 575,
    recurPeriod: .month, recurEvery: 1,
    onPay: {},
    pendingPayId: pendingId)
}

#Preview("Scheduled rows") {
  let data = PreviewData()
  let pendingId = UUID()
  return List {
    Section("Overdue") { overdueScheduledRow(data: data) }
    Section("Due Today") { dueTodayScheduledRow(data: data) }
    Section("Inline Pay") { payAffordanceScheduledRow(data: data) }
    Section("Paying (in-progress)") { payingScheduledRow(data: data, pendingId: pendingId) }
  }
}
