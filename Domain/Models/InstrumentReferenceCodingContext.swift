import Foundation
import os

/// Per-encoder or per-decoder state for representing nested instruments by ID.
///
/// Reference semantics are required because `ExportedData` installs the decoded
/// catalogue before its child models decode through the same `Decoder.userInfo`
/// value. Each context belongs to one synchronous encode or decode operation.
///
/// The catalogue is lock-protected because current SDKs require values stored
/// in `Encoder.userInfo` to be `Sendable`.
final class InstrumentReferenceCodingContext: Sendable {
  private let discoversReferences: Bool
  private let instrumentsById: OSAllocatedUnfairLock<[String: Instrument]>

  private init(
    discoversReferences: Bool = false,
    instrumentsById: [String: Instrument] = [:]
  ) {
    self.discoversReferences = discoversReferences
    self.instrumentsById = OSAllocatedUnfairLock(initialState: instrumentsById)
  }

  var catalogue: [Instrument] {
    instrumentsById.withLock { instruments in
      instruments.values.sorted { $0.id < $1.id }
    }
  }

  static func makeEncodingContext(
    instruments: [Instrument]
  ) throws -> InstrumentReferenceCodingContext {
    try makeContext(instruments: instruments, discoversReferences: false)
  }

  static func makeDiscoveryContext(
    instruments: [Instrument]
  ) throws -> InstrumentReferenceCodingContext {
    try makeContext(instruments: instruments, discoversReferences: true)
  }

  private static func makeContext(
    instruments: [Instrument],
    discoversReferences: Bool
  ) throws -> InstrumentReferenceCodingContext {
    var instrumentsById: [String: Instrument] = [:]
    for instrument in instruments {
      if let existing = instrumentsById[instrument.id], existing != instrument {
        throw EncodingError.invalidValue(
          instrument,
          EncodingError.Context(
            codingPath: [],
            debugDescription: "Conflicting definitions for instrument '\(instrument.id)'"
          ))
      }
      instrumentsById[instrument.id] = instrument
    }
    return InstrumentReferenceCodingContext(
      discoversReferences: discoversReferences,
      instrumentsById: instrumentsById)
  }

  static func makeDecodingContext() -> InstrumentReferenceCodingContext {
    InstrumentReferenceCodingContext()
  }

  func install(
    _ instruments: [Instrument],
    codingPath: [any CodingKey]
  ) throws {
    var decodedById: [String: Instrument] = [:]
    for instrument in instruments {
      if let existing = decodedById[instrument.id], existing != instrument {
        throw DecodingError.dataCorrupted(
          DecodingError.Context(
            codingPath: codingPath,
            debugDescription: "Conflicting definitions for instrument '\(instrument.id)'"
          ))
      }
      decodedById[instrument.id] = instrument
    }
    let installedInstruments = decodedById
    instrumentsById.withLock { $0 = installedInstruments }
  }

  func id(
    for instrument: Instrument,
    codingPath: [any CodingKey]
  ) throws -> String {
    try instrumentsById.withLock { instruments in
      guard let catalogueInstrument = instruments[instrument.id] else {
        if discoversReferences {
          instruments[instrument.id] = instrument
          return instrument.id
        }
        throw EncodingError.invalidValue(
          instrument,
          EncodingError.Context(
            codingPath: codingPath,
            debugDescription: "Instrument '\(instrument.id)' is missing from the export catalogue"
          ))
      }
      guard catalogueInstrument == instrument else {
        throw EncodingError.invalidValue(
          instrument,
          EncodingError.Context(
            codingPath: codingPath,
            debugDescription: "Instrument '\(instrument.id)' conflicts with the export catalogue"
          ))
      }
      return instrument.id
    }
  }

  func instrument(
    for id: String,
    codingPath: [any CodingKey]
  ) throws -> Instrument {
    try instrumentsById.withLock { instruments in
      guard let instrument = instruments[id] else {
        throw DecodingError.dataCorrupted(
          DecodingError.Context(
            codingPath: codingPath,
            debugDescription: "Instrument reference '\(id)' is missing from the export catalogue"
          ))
      }
      return instrument
    }
  }
}

extension CodingUserInfoKey {
  static var instrumentReferenceCodingContext: CodingUserInfoKey {
    guard
      let key = CodingUserInfoKey(
        rawValue: "rocks.moolah.export.instrument-reference-coding-context")
    else {
      preconditionFailure("The instrument coding context key must be valid")
    }
    return key
  }
}

extension Instrument: Codable {
  private enum CodingKeys: String, CodingKey {
    case id
    case kind
    case name
    case decimals
    case ticker
    case exchange
    case chainId
    case contractAddress
  }

  init(from decoder: any Decoder) throws {
    if let context = decoder.userInfo[.instrumentReferenceCodingContext]
      as? InstrumentReferenceCodingContext
    {
      let container = try decoder.singleValueContainer()
      let id = try container.decode(String.self)
      self = try context.instrument(for: id, codingPath: decoder.codingPath)
      return
    }

    try self.init(fullRepresentationFrom: decoder)
  }

  init(fullRepresentationFrom decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    kind = try container.decode(Kind.self, forKey: .kind)
    name = try container.decode(String.self, forKey: .name)
    decimals = try container.decode(Int.self, forKey: .decimals)
    ticker = try container.decodeIfPresent(String.self, forKey: .ticker)
    exchange = try container.decodeIfPresent(String.self, forKey: .exchange)
    chainId = try container.decodeIfPresent(Int.self, forKey: .chainId)
    contractAddress = try container.decodeIfPresent(String.self, forKey: .contractAddress)
  }

  func encode(to encoder: any Encoder) throws {
    if let context = encoder.userInfo[.instrumentReferenceCodingContext]
      as? InstrumentReferenceCodingContext
    {
      var container = encoder.singleValueContainer()
      try container.encode(context.id(for: self, codingPath: encoder.codingPath))
      return
    }

    try encodeFullRepresentation(to: encoder)
  }

  func encodeFullRepresentation(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(kind, forKey: .kind)
    try container.encode(name, forKey: .name)
    try container.encode(decimals, forKey: .decimals)
    try container.encodeIfPresent(ticker, forKey: .ticker)
    try container.encodeIfPresent(exchange, forKey: .exchange)
    try container.encodeIfPresent(chainId, forKey: .chainId)
    try container.encodeIfPresent(contractAddress, forKey: .contractAddress)
  }
}
