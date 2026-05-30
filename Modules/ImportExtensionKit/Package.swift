// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "ImportExtensionKit",
  platforms: [.iOS(.v26), .macOS(.v26)],
  products: [
    .library(name: "ImportExtensionKit", targets: ["ImportExtensionKit"])
  ],
  targets: [
    .target(name: "ImportExtensionKit"),
    .testTarget(name: "ImportExtensionKitTests", dependencies: ["ImportExtensionKit"]),
  ],
  swiftLanguageModes: [.v6])
