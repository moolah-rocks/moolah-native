import Foundation

/// Encodes and decodes the versioned profile-backup JSON document.
struct ExportDocumentCodec {
  func encode(_ data: ExportedData) throws -> Data {
    guard data.version == ExportFormatVersion.current else {
      throw EncodingError.invalidValue(
        data.version,
        EncodingError.Context(
          codingPath: [],
          debugDescription:
            "Only export format version \(ExportFormatVersion.current) can be encoded"
        ))
    }

    let discoveryContext = try InstrumentReferenceCodingContext.makeDiscoveryContext(
      instruments: data.instruments)
    let discoveryEncoder = Self.makeEncoder()
    discoveryEncoder.userInfo[.instrumentReferenceCodingContext] = discoveryContext
    _ = try discoveryEncoder.encode(data)

    let context = try InstrumentReferenceCodingContext.makeEncodingContext(
      instruments: discoveryContext.catalogue)
    let encoder = Self.makeEncoder()
    encoder.userInfo[.instrumentReferenceCodingContext] = context
    return try encoder.encode(data)
  }

  func decode(_ bytes: Data) throws -> ExportedData {
    let envelope = try Self.makeDecoder().decode(ExportVersionEnvelope.self, from: bytes)
    guard envelope.version >= ExportFormatVersion.oldestSupported,
      envelope.version <= ExportFormatVersion.current
    else {
      throw ExportError.unsupportedVersion(envelope.version)
    }

    let decoder = Self.makeDecoder()
    if envelope.version == ExportFormatVersion.current {
      decoder.userInfo[.instrumentReferenceCodingContext] =
        InstrumentReferenceCodingContext.makeDecodingContext()
    }
    let decoded = try decoder.decode(ExportedData.self, from: bytes)
    if envelope.version == 1 {
      return try decoded.normalizingInstrumentCatalogue()
    }
    return decoded
  }
}

extension ExportDocumentCodec {
  private struct ExportVersionEnvelope: Decodable {
    let version: Int
  }

  private static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }

  private static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
