import Foundation

/// All data exported from a profile, ready for serialization or import into SwiftData.
struct ExportedData {
  let version: Int
  let exportedAt: Date
  let profileLabel: String
  let currencyCode: String
  let financialYearStartMonth: Int
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
    version: Int = 1,
    exportedAt: Date = Date(),
    profileLabel: String = "",
    currencyCode: String = "",
    financialYearStartMonth: Int = 1,
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
  /// Custom decoding so export files written before `accountGroups`
  /// existed still import: the key is optional and defaults to empty.
  /// Every other field keeps its original required semantics. `encode`
  /// and `CodingKeys` stay synthesised, so new exports always write the key.
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    version = try container.decode(Int.self, forKey: .version)
    exportedAt = try container.decode(Date.self, forKey: .exportedAt)
    profileLabel = try container.decode(String.self, forKey: .profileLabel)
    currencyCode = try container.decode(String.self, forKey: .currencyCode)
    financialYearStartMonth = try container.decode(Int.self, forKey: .financialYearStartMonth)
    instruments = try container.decode([Instrument].self, forKey: .instruments)
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
}

extension JSONEncoder {
  static var exportEncoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }
}

extension JSONDecoder {
  static var exportDecoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
