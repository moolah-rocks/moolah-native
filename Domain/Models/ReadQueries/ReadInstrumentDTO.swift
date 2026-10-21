import Foundation

/// Deliberately narrow wire types. Provider metadata and internal models are never serialized.
struct ReadInstrumentDTO: Codable, Sendable, Equatable {
  let id: String
  let kind: String
  let displayDecimals: Int
  let storageScale: Int

  init(_ instrument: Instrument) {
    id = instrument.id
    kind = instrument.kind.rawValue
    displayDecimals = instrument.decimals
    storageScale = 8
  }
}

struct ReadQuantityDTO: Codable, Sendable, Equatable {
  let quantity: String
  let instrument: ReadInstrumentDTO

  init(quantity: Decimal, instrument: Instrument) {
    self.quantity = NSDecimalNumber(decimal: quantity).stringValue
    self.instrument = ReadInstrumentDTO(instrument)
  }
}

struct ReadAccountDTO: Codable, Sendable, Equatable {
  let id: UUID
  let name: String
  let type: String
  let primaryInstrument: ReadInstrumentDTO
  let isHidden: Bool
}

struct ReadCategoryDTO: Codable, Sendable, Equatable {
  let id: UUID
  let name: String
  let parentID: UUID?
}

struct ReadEarmarkDTO: Codable, Sendable, Equatable {
  let primaryInstrument: ReadInstrumentDTO
  let id: UUID
  let name: String
  let isHidden: Bool
  let target: ReadQuantityDTO?
  let positions: [ReadQuantityDTO]
}

struct ReadBalanceDTO: Codable, Sendable, Equatable {
  let accountID: UUID
  let positions: [ReadQuantityDTO]
}
