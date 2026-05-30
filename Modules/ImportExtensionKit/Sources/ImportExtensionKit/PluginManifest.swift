public struct PluginManifest: Sendable, Hashable {
  public let host: String
  public let pathPrefix: String
  public let jsResource: String
  public let displayName: String
  /// Optional copy shown by the extension when the parser returns zero
  /// rows. When nil, the extension's generic empty-state copy is used.
  /// Example: "Open one of your accounts to see transactions before
  /// importing."
  public let emptyHint: String?

  public init(
    host: String,
    pathPrefix: String,
    jsResource: String,
    displayName: String,
    emptyHint: String? = nil
  ) {
    self.host = host
    self.pathPrefix = pathPrefix
    self.jsResource = jsResource
    self.displayName = displayName
    self.emptyHint = emptyHint
  }
}
