import Foundation
import GRDB

@testable import Moolah

struct ReportingStoreTaxBackendContext {
  let backend: any BackendProvider
  let database: DatabaseQueue
  let account: Account
  let bhp: Instrument
  let spam: Instrument
}

struct ReportingStoreProfitLossFixture {
  let context: ReportingStoreTaxBackendContext
  let eofy: Date
  let later: Date

  var backend: any BackendProvider { context.backend }
  var bhp: Instrument { context.bhp }
  var spam: Instrument { context.spam }
}

struct ReportingStoreCapitalGainsFixture {
  let context: ReportingStoreTaxBackendContext

  var backend: any BackendProvider { context.backend }
  var bhp: Instrument { context.bhp }
  var spam: Instrument { context.spam }
}

func reportingStoreBuy(
  instrument: Instrument,
  quantity: Decimal,
  cost: Decimal,
  date: Date,
  in context: ReportingStoreTaxBackendContext,
  account: Account? = nil,
  profileInstrument: Instrument = .AUD
) -> Transaction {
  let accountId = account?.id ?? context.account.id
  return Transaction(
    date: date,
    legs: [
      TransactionLeg(
        accountId: accountId, instrument: profileInstrument, quantity: -cost, type: .trade),
      TransactionLeg(
        accountId: accountId, instrument: instrument, quantity: quantity, type: .trade),
    ])
}

func reportingStoreSell(
  instrument: Instrument,
  quantity: Decimal,
  proceeds: Decimal,
  date: Date,
  in context: ReportingStoreTaxBackendContext,
  account: Account? = nil,
  profileInstrument: Instrument = .AUD
) -> Transaction {
  let accountId = account?.id ?? context.account.id
  return Transaction(
    date: date,
    legs: [
      TransactionLeg(
        accountId: accountId, instrument: instrument, quantity: -quantity, type: .trade),
      TransactionLeg(
        accountId: accountId,
        instrument: profileInstrument,
        quantity: proceeds,
        type: .trade),
    ])
}

func reportingStoreIncome(
  instrument: Instrument,
  quantity: Decimal,
  date: Date,
  in context: ReportingStoreTaxBackendContext,
  account: Account? = nil
) -> Transaction {
  let accountId = account?.id ?? context.account.id
  return Transaction(
    date: date,
    legs: [
      TransactionLeg(
        accountId: accountId, instrument: instrument, quantity: quantity, type: .income)
    ])
}

func reportingStoreSpend(
  instrument: Instrument,
  quantity: Decimal,
  date: Date,
  in context: ReportingStoreTaxBackendContext,
  account: Account? = nil
) -> Transaction {
  let accountId = account?.id ?? context.account.id
  return Transaction(
    date: date,
    legs: [
      TransactionLeg(
        accountId: accountId,
        instrument: instrument,
        quantity: -quantity,
        type: .expense)
    ])
}
