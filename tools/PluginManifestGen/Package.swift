// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "PluginManifestGen",
  platforms: [.macOS(.v26)],
  targets: [
    .executableTarget(name: "PluginManifestGen"),
    .testTarget(name: "PluginManifestGenTests", dependencies: ["PluginManifestGen"]),
  ],
  swiftLanguageModes: [.v6])
