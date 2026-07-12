import Foundation

/// All data exported from a profile, ready for serialization or import into SwiftData.
struct ExportedData {
  let version: Int
  let exportedAt: Date
  let profileLabel: String
  let currencyCode: String
  let financialYearStartMonth: Int
  let defaultTaxOwnerId: UUID?
  let taxOwners: [TaxOwner]
  let instruments: [Instrument]
  let accounts: [Account]
  /// Sidebar account groups. Accounts reference their group by
  /// `Account.groupId`; without the group records here, imported
  /// accounts would carry dangling references and lose their grouping.
  let accountGroups: [AccountGroup]
  let categories: [Category]
  let earmarks: [Earmark]
  let earmarkBudgets: [UUID: [EarmarkBudgetItem]]
  let transactions: [Transaction]
  let investmentValues: [UUID: [InvestmentValue]]

  init(
    version: Int = ExportFormatVersion.current,
    exportedAt: Date = Date(),
    profileLabel: String = "",
    currencyCode: String = "",
    financialYearStartMonth: Int = 1,
    defaultTaxOwnerId: UUID? = nil,
    taxOwners: [TaxOwner] = [],
    instruments: [Instrument] = [],
    accounts: [Account],
    accountGroups: [AccountGroup] = [],
    categories: [Category],
    earmarks: [Earmark],
    earmarkBudgets: [UUID: [EarmarkBudgetItem]],
    transactions: [Transaction],
    investmentValues: [UUID: [InvestmentValue]]
  ) {
    self.version = version
    self.exportedAt = exportedAt
    self.profileLabel = profileLabel
    self.currencyCode = currencyCode
    self.financialYearStartMonth = financialYearStartMonth
    self.defaultTaxOwnerId = defaultTaxOwnerId
    self.taxOwners = taxOwners
    self.instruments = instruments
    self.accounts = accounts
    self.accountGroups = accountGroups
    self.categories = categories
    self.earmarks = earmarks
    self.earmarkBudgets = earmarkBudgets
    self.transactions = transactions
    self.investmentValues = investmentValues
  }
}

extension ExportedData: Sendable {}

extension ExportedData: Codable {
  private enum CodingKeys: String, CodingKey {
    case version
    case exportedAt
    case profileLabel
    case currencyCode
    case financialYearStartMonth
    case defaultTaxOwnerId
    case taxOwners
    case instruments
    case accounts
    case accountGroups
    case categories
    case earmarks
    case earmarkBudgets
    case transactions
    case investmentValues
  }

  /// Custom decoding keeps exports written before account groups and tax
  /// ownership metadata existed importable. Missing collection keys default
  /// to empty; a missing default-owner id remains `nil` so a newly imported
  /// profile derives its own default. The matching encoder writes every
  /// top-level key while allowing nested domain models to keep their own
  /// Codable implementations.
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    version = try container.decode(Int.self, forKey: .version)
    exportedAt = try container.decode(Date.self, forKey: .exportedAt)
    profileLabel = try container.decode(String.self, forKey: .profileLabel)
    currencyCode = try container.decode(String.self, forKey: .currencyCode)
    financialYearStartMonth = try container.decode(Int.self, forKey: .financialYearStartMonth)
    defaultTaxOwnerId = try container.decodeIfPresent(UUID.self, forKey: .defaultTaxOwnerId)
    taxOwners = try container.decodeIfPresent([TaxOwner].self, forKey: .taxOwners) ?? []
    if version == ExportFormatVersion.current {
      guard
        let context = decoder.userInfo[.instrumentReferenceCodingContext]
          as? InstrumentReferenceCodingContext
      else {
        throw DecodingError.dataCorrupted(
          DecodingError.Context(
            codingPath: decoder.codingPath,
            debugDescription: "Export format version 2 requires the export document codec"
          ))
      }
      let wrapped = try container.decode([FullInstrument].self, forKey: .instruments)
      let decodedInstruments = wrapped.map(\.instrument)
      try context.install(
        decodedInstruments,
        codingPath: decoder.codingPath + [CodingKeys.instruments])
      instruments = context.catalogue
    } else {
      instruments = try container.decode([Instrument].self, forKey: .instruments)
    }
    accounts = try container.decode([Account].self, forKey: .accounts)
    accountGroups =
      try container.decodeIfPresent([AccountGroup].self, forKey: .accountGroups) ?? []
    categories = try container.decode([Category].self, forKey: .categories)
    earmarks = try container.decode([Earmark].self, forKey: .earmarks)
    earmarkBudgets = try container.decode(
      [UUID: [EarmarkBudgetItem]].self, forKey: .earmarkBudgets)
    transactions = try container.decode([Transaction].self, forKey: .transactions)
    investmentValues = try container.decode(
      [UUID: [InvestmentValue]].self, forKey: .investmentValues)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(version, forKey: .version)
    try container.encode(exportedAt, forKey: .exportedAt)
    try container.encode(profileLabel, forKey: .profileLabel)
    try container.encode(currencyCode, forKey: .currencyCode)
    try container.encode(financialYearStartMonth, forKey: .financialYearStartMonth)
    try container.encodeIfPresent(defaultTaxOwnerId, forKey: .defaultTaxOwnerId)
    try container.encode(taxOwners, forKey: .taxOwners)
    if version == ExportFormatVersion.current {
      guard
        let context = encoder.userInfo[.instrumentReferenceCodingContext]
          as? InstrumentReferenceCodingContext
      else {
        throw EncodingError.invalidValue(
          version,
          EncodingError.Context(
            codingPath: encoder.codingPath,
            debugDescription: "Export format version 2 requires the export document codec"
          ))
      }
      try container.encode(context.catalogue.map(FullInstrument.init), forKey: .instruments)
    } else {
      try container.encode(instruments, forKey: .instruments)
    }
    try container.encode(accounts, forKey: .accounts)
    try container.encode(accountGroups, forKey: .accountGroups)
    try container.encode(categories, forKey: .categories)
    try container.encode(earmarks, forKey: .earmarks)
    try container.encode(earmarkBudgets, forKey: .earmarkBudgets)
    try container.encode(transactions, forKey: .transactions)
    try container.encode(investmentValues, forKey: .investmentValues)
  }
}

extension ExportedData {
  func normalizingInstrumentCatalogue() throws -> ExportedData {
    var byId: [String: Instrument] = [:]
    for instrument in allReferencedInstruments {
      if let existing = byId[instrument.id], existing != instrument {
        throw DecodingError.dataCorrupted(
          DecodingError.Context(
            codingPath: [],
            debugDescription: "Conflicting definitions for instrument '\(instrument.id)'"
          ))
      }
      byId[instrument.id] = instrument
    }
    return ExportedData(
      version: version,
      exportedAt: exportedAt,
      profileLabel: profileLabel,
      currencyCode: currencyCode,
      financialYearStartMonth: financialYearStartMonth,
      defaultTaxOwnerId: defaultTaxOwnerId,
      taxOwners: taxOwners,
      instruments: byId.values.sorted { $0.id < $1.id },
      accounts: accounts,
      accountGroups: accountGroups,
      categories: categories,
      earmarks: earmarks,
      earmarkBudgets: earmarkBudgets,
      transactions: transactions,
      investmentValues: investmentValues
    )
  }

  private var allReferencedInstruments: [Instrument] {
    instruments
      + accounts.map(\.instrument)
      + accountGroups.map(\.instrument)
      + earmarks.flatMap { earmark in
        [earmark.instrument] + [earmark.savingsGoal?.instrument].compactMap { $0 }
      }
      + earmarkBudgets.values.flatMap { items in items.map(\.amount.instrument) }
      + transactions.flatMap { transaction in transaction.legs.map(\.instrument) }
      + investmentValues.values.flatMap { values in values.map(\.value.instrument) }
  }
}

private struct FullInstrument {
  let instrument: Instrument

  init(_ instrument: Instrument) {
    self.instrument = instrument
  }

}

extension FullInstrument: Codable {
  init(from decoder: any Decoder) throws {
    instrument = try Instrument(fullRepresentationFrom: decoder)
  }

  func encode(to encoder: any Encoder) throws {
    try instrument.encodeFullRepresentation(to: encoder)
  }
}
