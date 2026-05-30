/// In-memory lookup over the set of `PluginManifest`s the extension
/// knows about. Constructed once from `PluginRegistry+Bundled` (the
/// compile-time set baked in by `PluginManifestGen` from
/// `Plugins/plugins.json`) and consulted whenever a `(host, path)` pair
/// from the live web page needs to be mapped to a plugin to run.
///
/// The lookup is small and linear (one entry per supported bank /
/// brokerage), so an array scan is fine and we don't need a hash index.
public struct PluginRegistry: Sendable {
  public let manifests: [PluginManifest]

  /// Build a registry over the given manifests. The order is
  /// significant only when two manifests would both match a `(host,
  /// path)` pair — `match` returns the first matching entry, so put
  /// more-specific manifests (e.g. `chase.com/business`) before
  /// less-specific ones (`chase.com/`) in the source list.
  public init(manifests: [PluginManifest]) {
    self.manifests = manifests
  }

  /// Look up the plugin manifest for a live page's host and path.
  ///
  /// Host matching is exact OR dotted-suffix: `manifest.host = "chase.com"`
  /// matches the literal host `chase.com` and any subdomain like
  /// `secure.chase.com`. It does NOT match `x-chase.com` —
  /// the leading dot is the phishing guard.
  ///
  /// Path matching is `hasPrefix(manifest.pathPrefix)` so a manifest
  /// scoped to `/banking/` won't fire on the marketing homepage `/`.
  ///
  /// Returns `nil` when no manifest matches.
  public func match(host: String, path: String) -> PluginManifest? {
    manifests.first { manifest in
      let hostMatches = host == manifest.host || host.hasSuffix("." + manifest.host)
      let pathMatches = path.hasPrefix(manifest.pathPrefix)
      return hostMatches && pathMatches
    }
  }
}
