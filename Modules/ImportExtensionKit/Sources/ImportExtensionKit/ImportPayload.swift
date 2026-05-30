import Foundation

public struct ImportPayload {
  public let schemaVersion: Int
  public let sourceHost: String
  public let sourceURL: String
  public let capturedAt: Date
  public let accountHint: String?
  public let currencyHint: String?
  public let rows: [ImportPayloadRow]

  /// Memberwise initialiser. Swift's synthesised memberwise init for a
  /// public struct is `internal`, so we have to spell the `public` form
  /// out for cross-module construction (the iOS / macOS extension
  /// principals and the app target both call it). This is the documented
  /// exception to CODE_GUIDE.md §10 — without it, callers outside
  /// `ImportExtensionKit` cannot construct a payload.
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

extension ImportPayload: Sendable {}

extension ImportPayload: Equatable {}

extension ImportPayload {
  /// Returns a copy of the payload with `sourceURL`'s query string and
  /// fragment removed. Bank URLs sometimes encode short-lived session
  /// tokens in the query string; stripping them before the payload
  /// crosses the App Group boundary avoids unnecessarily retaining
  /// sensitive bearer-style data on disk.
  ///
  /// The returned `sourceURL` is the original URL's scheme + host + path.
  /// A malformed URL or one missing a scheme is returned unchanged so
  /// the caller never sees an empty string where it expected a host.
  public func strippingSourceURLQueryAndFragment() -> ImportPayload {
    guard
      var components = URLComponents(string: sourceURL),
      components.scheme != nil
    else { return self }
    components.queryItems = nil
    components.query = nil
    components.fragment = nil
    guard let stripped = components.url?.absoluteString else { return self }
    return ImportPayload(
      schemaVersion: schemaVersion,
      sourceHost: sourceHost,
      sourceURL: stripped,
      capturedAt: capturedAt,
      accountHint: accountHint,
      currencyHint: currencyHint,
      rows: rows)
  }
}

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

  /// Public memberwise initialiser with default-nil for the optional
  /// fields. Same rationale as `ImportPayload.init` — Swift's
  /// synthesised memberwise init for a public struct is `internal`,
  /// so cross-module construction (tests, app target, principals)
  /// needs this spelled out. The defaults are pure caller ergonomics
  /// so most callers can omit `balance:` and `reference:`.
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
  public static let importPayload: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()
}

extension JSONEncoder {
  public static let importPayload: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }()
}
