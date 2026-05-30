import Foundation

public struct Manifest: Codable, Equatable, Sendable {
  public let host: String
  public let pathPrefix: String
  public let file: String
  public let displayName: String

  public init(host: String, pathPrefix: String, file: String, displayName: String) {
    self.host = host
    self.pathPrefix = pathPrefix
    self.file = file
    self.displayName = displayName
  }
}

public struct ManifestIndex: Codable, Sendable {
  public let plugins: [Manifest]
}
