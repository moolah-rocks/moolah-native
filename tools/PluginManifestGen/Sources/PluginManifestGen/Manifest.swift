import Foundation

public struct Manifest: Codable, Equatable, Sendable {
  public let host: String
  public let pathPrefix: String
  public let file: String
  public let displayName: String
  /// Optional copy shown by the extension when the parser returns zero
  /// rows. When nil, the extension's generic empty-state copy is used.
  /// Example: "Open one of your accounts to see transactions before
  /// importing."
  public let emptyHint: String?

  public init(
    host: String,
    pathPrefix: String,
    file: String,
    displayName: String,
    emptyHint: String? = nil
  ) {
    self.host = host
    self.pathPrefix = pathPrefix
    self.file = file
    self.displayName = displayName
    self.emptyHint = emptyHint
  }
}

public struct ManifestIndex: Codable, Sendable {
  public let plugins: [Manifest]
}
