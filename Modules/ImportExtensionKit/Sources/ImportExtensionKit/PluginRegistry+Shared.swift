extension PluginRegistry {
  /// Process-wide registry populated from the generated `BundledPlugins.all`.
  /// The extension principal uses this to resolve the display name shown in
  /// the confirmation sheet; the main app reads from the same registry when
  /// rendering inbox entries.
  public static let shared = PluginRegistry(manifests: BundledPlugins.all)
}
