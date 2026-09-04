import Foundation
import GRDB

// Transfer-detection baseline seed helpers for `UITestSeedHydrator`.
//
// Seeds a CloudKit profile, two bank accounts, and four imported
// single-account transactions forming one suggestion pair. A separate
// `TransferSuggestion` record is indexed by both transaction IDs, so the
// standard transaction inspector offers the
// transfer action at first launch with no detection-timing dependency.
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
      try seedTransferDetectionPair(instrument: instrument, in: database)
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

  /// Seeds the detected pair. `importedAt` is anchored relative to
  /// "now" so the rows fall inside the default 24-hour Recently Added
  /// window whenever the suite runs; the transaction date and every
  /// UUID stay deterministic.
  private static func seedTransferDetectionPair(
    instrument: Instrument, in database: Database
  ) throws {
    let importedAt = Date().addingTimeInterval(-3600)
    let importSessionId = UITestFixtures.TransferDetection.profileId
    try seedSuggestionPair(
      instrument: instrument,
      importedAt: importedAt,
      importSessionId: importSessionId,
      in: database)
  }

  private static func seedSuggestionPair(
    instrument: Instrument,
    importedAt: Date,
    importSessionId: UUID,
    in database: Database
  ) throws {
    let fixtures = UITestFixtures.TransferDetection.self
    try upsertSuggestedTransfer(
      SuggestedTransferSpec(
        id: fixtures.primaryOutgoingId,
        payee: fixtures.primaryOutgoingPayee,
        date: fixtures.primaryOutgoingDate,
        accountId: fixtures.everydayAccountId,
        amount: InstrumentAmount(
          quantity: -Decimal(fixtures.primaryOutgoingCents) / 100,
          instrument: instrument),
        type: .expense,
        counterpartId: fixtures.primaryIncomingId,
        suggestedAt: fixtures.suggestedAt,
        importedAt: importedAt,
        importSessionId: importSessionId),
      in: database)
    try upsertSuggestedTransfer(
      SuggestedTransferSpec(
        id: fixtures.primaryIncomingId,
        payee: fixtures.primaryIncomingPayee,
        date: fixtures.primaryIncomingDate,
        accountId: fixtures.savingsAccountId,
        amount: InstrumentAmount(
          quantity: Decimal(fixtures.primaryIncomingCents) / 100,
          instrument: instrument),
        type: .income,
        counterpartId: fixtures.primaryOutgoingId,
        suggestedAt: fixtures.suggestedAt,
        importedAt: importedAt,
        importSessionId: importSessionId),
      in: database)
    try upsertSuggestedTransferRecord(
      transactionId: fixtures.primaryOutgoingId,
      counterpartId: fixtures.primaryIncomingId,
      suggestedAt: fixtures.suggestedAt,
      in: database)
  }
}
