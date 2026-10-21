import Foundation

/// A price is separate from native quantities and local sync freshness. Missing prices are nil.
struct ReadValuationDTO: Codable, Sendable {
  let value: ReadQuantityDTO?
  let reportingInstrument: ReadInstrumentDTO
  let status: String
  let requestedAt: Date?
  let oldestPriceAt: Date?
  let provenance: String
  let errorCode: String?
}

/// Native holdings are retained even when a reporting value cannot be calculated.
struct ReadValuedPositionDTO: Codable, Sendable {
  let native: ReadQuantityDTO
  let valuation: ReadValuationDTO
}

/// Includes every requested account, with each instrument valued separately and a complete-only total.
struct ReadValuedBalanceDTO: Codable, Sendable {
  let accountID: UUID
  let positions: [ReadValuedPositionDTO]
  let total: ReadValuationDTO
}

/// Report signs are preserved: spending is normally negative, refunds can be positive.
struct ReadSummaryGroupDTO: Codable, Sendable {
  let categoryID: UUID?
  let income: [ReadQuantityDTO]
  let spending: [ReadQuantityDTO]
  let reportingIncome: ReadValuationDTO
  let reportingSpending: ReadValuationDTO
}

/// Flows cover the requested date range; net worth is explicitly the current posted position.
struct ReadSummaryDTO: Codable, Sendable {
  let semantics: String
  let reportingInstrument: ReadInstrumentDTO
  let income: [ReadQuantityDTO]
  let spending: [ReadQuantityDTO]
  let reportingIncome: ReadValuationDTO
  let reportingSpending: ReadValuationDTO
  let currentNetWorth: ReadValuationDTO
  let groups: [ReadSummaryGroupDTO]
}

/// Calculation state keeps Decimal quantities until the final wire conversion; never reparse money DTOs.
struct ReadValuation: Sendable {
  let amount: InstrumentAmount?
  let reportingInstrument: Instrument
  let status: String
  let requestedAt: Date?
  let oldestPriceAt: Date?
  let provenance: String
  let errorCode: String?

  var dto: ReadValuationDTO {
    ReadValuationDTO(
      value: amount.map { ReadQuantityDTO(quantity: $0.quantity, instrument: $0.instrument) },
      reportingInstrument: ReadInstrumentDTO(reportingInstrument),
      status: status,
      requestedAt: requestedAt,
      oldestPriceAt: oldestPriceAt,
      provenance: provenance,
      errorCode: errorCode
    )
  }
}

extension ReadValuationDTO {
  private enum CodingKeys: String, CodingKey {
    case value, reportingInstrument, status, requestedAt, oldestPriceAt, provenance, errorCode
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(value, forKey: .value)
    try container.encode(reportingInstrument, forKey: .reportingInstrument)
    try container.encode(status, forKey: .status)
    try container.encode(requestedAt, forKey: .requestedAt)
    try container.encode(oldestPriceAt, forKey: .oldestPriceAt)
    try container.encode(provenance, forKey: .provenance)
    try container.encode(errorCode, forKey: .errorCode)
  }
}
