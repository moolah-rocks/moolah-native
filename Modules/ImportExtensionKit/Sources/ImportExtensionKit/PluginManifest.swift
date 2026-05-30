public struct PluginManifest: Sendable, Hashable {
  public let host: String
  public let pathPrefix: String
  public let jsResource: String
  public let displayName: String

  public init(host: String, pathPrefix: String, jsResource: String, displayName: String) {
    self.host = host
    self.pathPrefix = pathPrefix
    self.jsResource = jsResource
    self.displayName = displayName
  }
}
