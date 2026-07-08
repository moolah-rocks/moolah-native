import Foundation

struct Profile: Identifiable, Sendable, Equatable {
  let id: UUID
  var label: String
  var currencyCode: String
  var financialYearStartMonth: Int
  var defaultTaxOwnerId: UUID
  let createdAt: Date
  var dataFormatVersion: Int

  init(
    id: UUID = UUID(),
    label: String,
    currencyCode: String = "AUD",
    financialYearStartMonth: Int = 7,
    defaultTaxOwnerId: UUID? = nil,
    createdAt: Date = Date(),
    dataFormatVersion: Int = 0
  ) {
    self.id = id
    self.label = label
    self.currencyCode = currencyCode
    self.financialYearStartMonth = financialYearStartMonth
    self.defaultTaxOwnerId = defaultTaxOwnerId ?? TaxOwner.defaultOwnerId(for: id)
    self.createdAt = createdAt
    self.dataFormatVersion = dataFormatVersion
  }

  var instrument: Instrument {
    Instrument.fiat(code: currencyCode)
  }
}

extension Profile: Codable {
  private enum CodingKeys: String, CodingKey {
    case id
    case label
    case currencyCode
    case financialYearStartMonth
    case defaultTaxOwnerId
    case createdAt
    case dataFormatVersion
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    label = try container.decode(String.self, forKey: .label)
    currencyCode = try container.decodeIfPresent(String.self, forKey: .currencyCode) ?? "AUD"
    financialYearStartMonth =
      try container.decodeIfPresent(Int.self, forKey: .financialYearStartMonth) ?? 7
    defaultTaxOwnerId =
      try container.decodeIfPresent(UUID.self, forKey: .defaultTaxOwnerId)
      ?? TaxOwner.defaultOwnerId(for: id)
    createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    dataFormatVersion = try container.decodeIfPresent(Int.self, forKey: .dataFormatVersion) ?? 0
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(label, forKey: .label)
    try container.encode(currencyCode, forKey: .currencyCode)
    try container.encode(financialYearStartMonth, forKey: .financialYearStartMonth)
    try container.encode(defaultTaxOwnerId, forKey: .defaultTaxOwnerId)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(dataFormatVersion, forKey: .dataFormatVersion)
  }
}
