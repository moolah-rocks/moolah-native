import Foundation

public struct ImportPayload: Sendable {
  public let schemaVersion: Int
  public let sourceHost: String
  public let sourceURL: String
  public let capturedAt: Date
  public let accountHint: String?
  public let currencyHint: String?
  public let rows: [ImportPayloadRow]

  public init(
    schemaVersion: Int,
    sourceHost: String,
    sourceURL: String,
    capturedAt: Date,
    accountHint: String?,
    currencyHint: String?,
    rows: [ImportPayloadRow]
  ) {
    self.schemaVersion = schemaVersion
    self.sourceHost = sourceHost
    self.sourceURL = sourceURL
    self.capturedAt = capturedAt
    self.accountHint = accountHint
    self.currencyHint = currencyHint
    self.rows = rows
  }
}

extension ImportPayload: Equatable {}

extension ImportPayload: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .schemaVersion)
    guard version == 1 else {
      throw ImportPayloadDecodingError.unsupportedSchemaVersion(version)
    }
    self.schemaVersion = version
    self.sourceHost = try container.decode(String.self, forKey: .sourceHost)
    self.sourceURL = try container.decode(String.self, forKey: .sourceURL)
    self.capturedAt = try container.decode(Date.self, forKey: .capturedAt)
    self.accountHint = try container.decodeIfPresent(String.self, forKey: .accountHint)
    self.currencyHint = try container.decodeIfPresent(String.self, forKey: .currencyHint)
    self.rows = try container.decode([ImportPayloadRow].self, forKey: .rows)
  }
}

public struct ImportPayloadRow: Codable, Sendable, Equatable {
  public let date: String
  public let amount: String
  public let description: String
  public let balance: String?
  public let reference: String?

  public init(
    date: String,
    amount: String,
    description: String,
    balance: String? = nil,
    reference: String? = nil
  ) {
    self.date = date
    self.amount = amount
    self.description = description
    self.balance = balance
    self.reference = reference
  }
}

public enum ImportPayloadDecodingError: Error, Equatable {
  case unsupportedSchemaVersion(Int)
}

extension JSONDecoder {
  // Configured once during initialisation; Foundation documents JSONDecoder.decode
  // as thread-safe after configuration, so sharing a single instance is safe.
  nonisolated(unsafe) public static let importPayload: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()
}

extension JSONEncoder {
  // Configured once during initialisation; Foundation documents JSONEncoder.encode
  // as thread-safe after configuration, so sharing a single instance is safe.
  nonisolated(unsafe) public static let importPayload: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }()
}
