import Foundation
import GRDB

// Transfer-detection baseline seed helpers for `UITestSeedHydrator`.
//
// Seeds a CloudKit profile, two bank accounts, and four imported
// single-account transactions forming a merge pair and a dismiss pair.
// Both members of each pair carry a `TransferSuggestion` pointing at
// the other so the passive Recently Added pill renders for all four
// rows at first launch with no detection-timing dependency.
extension UITestSeedHydrator {
  static func hydrateTransferDetectionBaseline(
    into manager: ProfileContainerManager
  ) throws -> Profile {
    let fixtures = UITestFixtures.TransferDetection.self

    let profile = Profile(
      id: fixtures.profileId,
      label: fixtures.profileLabel,
      currencyCode: fixtures.profileCurrencyCode,
      financialYearStartMonth: 7,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    try upsertProfile(profile, into: manager)

    let database = try manager.database(for: profile.id)
    let instrument = profile.instrument

    // Instrument identity lives on the shared profile-index registry —
    // register the profile denomination before any leg fans a domain
    // `Instrument` out of it.
    try manager.profileIndexDatabase.write { database in
      try upsertInstrument(instrument, in: database)
    }

    try database.write { database in
      try seedTransferDetectionAccounts(instrument: instrument, in: database)
      try seedTransferDetectionPairs(instrument: instrument, in: database)
    }
    return profile
  }

  private static func seedTransferDetectionAccounts(
    instrument: Instrument, in database: Database
  ) throws {
    let fixtures = UITestFixtures.TransferDetection.self
    try upsertAccount(
      AccountSpec(
        id: fixtures.everydayAccountId,
        name: fixtures.everydayAccountName,
        type: .bank,
        instrumentId: instrument.id,
        position: 0),
      in: database)
    try upsertAccount(
      AccountSpec(
        id: fixtures.savingsAccountId,
        name: fixtures.savingsAccountName,
        type: .bank,
        instrumentId: instrument.id,
        position: 1),
      in: database)
  }

  /// Seeds both detected pairs. `importedAt` is anchored relative to
  /// "now" so the rows fall inside the default 24-hour Recently Added
  /// window whenever the suite runs; the transaction date and every
  /// UUID stay deterministic.
  private static func seedTransferDetectionPairs(
    instrument: Instrument, in database: Database
  ) throws {
    let importedAt = Date().addingTimeInterval(-3600)
    let importSessionId = UITestFixtures.TransferDetection.profileId
    try seedMergePair(
      instrument: instrument,
      importedAt: importedAt,
      importSessionId: importSessionId,
      in: database)
    try seedDismissPair(
      instrument: instrument,
      importedAt: importedAt,
      importSessionId: importSessionId,
      in: database)
  }

  private static func seedMergePair(
    instrument: Instrument,
    importedAt: Date,
    importSessionId: UUID,
    in database: Database
  ) throws {
    let fixtures = UITestFixtures.TransferDetection.self
    try upsertSuggestedTransfer(
      SuggestedTransferSpec(
        id: fixtures.mergeOutgoingId,
        payee: fixtures.mergeOutgoingPayee,
        date: fixtures.mergeOutgoingDate,
        accountId: fixtures.everydayAccountId,
        amount: InstrumentAmount(
          quantity: -Decimal(fixtures.mergeOutgoingCents) / 100,
          instrument: instrument),
        type: .expense,
        counterpartId: fixtures.mergeIncomingId,
        suggestedAt: fixtures.suggestedAt,
        importedAt: importedAt,
        importSessionId: importSessionId),
      in: database)
    try upsertSuggestedTransfer(
      SuggestedTransferSpec(
        id: fixtures.mergeIncomingId,
        payee: fixtures.mergeIncomingPayee,
        date: fixtures.mergeIncomingDate,
        accountId: fixtures.savingsAccountId,
        amount: InstrumentAmount(
          quantity: Decimal(fixtures.mergeIncomingCents) / 100,
          instrument: instrument),
        type: .income,
        counterpartId: fixtures.mergeOutgoingId,
        suggestedAt: fixtures.suggestedAt,
        importedAt: importedAt,
        importSessionId: importSessionId),
      in: database)
    try upsertSuggestedTransferRecord(
      transactionId: fixtures.mergeOutgoingId,
      counterpartId: fixtures.mergeIncomingId,
      suggestedAt: fixtures.suggestedAt,
      in: database)
  }

  private static func seedDismissPair(
    instrument: Instrument,
    importedAt: Date,
    importSessionId: UUID,
    in database: Database
  ) throws {
    let fixtures = UITestFixtures.TransferDetection.self
    try upsertSuggestedTransfer(
      SuggestedTransferSpec(
        id: fixtures.dismissOutgoingId,
        payee: fixtures.dismissOutgoingPayee,
        date: fixtures.dismissOutgoingDate,
        accountId: fixtures.everydayAccountId,
        amount: InstrumentAmount(
          quantity: -Decimal(fixtures.dismissOutgoingCents) / 100,
          instrument: instrument),
        type: .expense,
        counterpartId: fixtures.dismissIncomingId,
        suggestedAt: fixtures.suggestedAt,
        importedAt: importedAt,
        importSessionId: importSessionId),
      in: database)
    try upsertSuggestedTransfer(
      SuggestedTransferSpec(
        id: fixtures.dismissIncomingId,
        payee: fixtures.dismissIncomingPayee,
        date: fixtures.dismissIncomingDate,
        accountId: fixtures.savingsAccountId,
        amount: InstrumentAmount(
          quantity: Decimal(fixtures.dismissIncomingCents) / 100,
          instrument: instrument),
        type: .income,
        counterpartId: fixtures.dismissOutgoingId,
        suggestedAt: fixtures.suggestedAt,
        importedAt: importedAt,
        importSessionId: importSessionId),
      in: database)
    try upsertSuggestedTransferRecord(
      transactionId: fixtures.dismissOutgoingId,
      counterpartId: fixtures.dismissIncomingId,
      suggestedAt: fixtures.suggestedAt,
      in: database)
  }
}
