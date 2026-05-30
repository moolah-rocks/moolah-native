public struct PluginRegistry: Sendable {
  public let manifests: [PluginManifest]

  public init(manifests: [PluginManifest]) {
    self.manifests = manifests
  }

  /// Exact-host or dotted-suffix match, AND path prefix match.
  /// "x-chase.com" does NOT match "chase.com" — that's the phishing guard.
  public func match(host: String, path: String) -> PluginManifest? {
    manifests.first { manifest in
      let hostMatches = host == manifest.host || host.hasSuffix("." + manifest.host)
      let pathMatches = path.hasPrefix(manifest.pathPrefix)
      return hostMatches && pathMatches
    }
  }
}
