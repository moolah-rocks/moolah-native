// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "HelpGen",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "help-gen", targets: ["HelpGen"])
  ],
  targets: [
    .executableTarget(name: "HelpGen"),
    .testTarget(name: "HelpGenTests", dependencies: ["HelpGen"]),
  ]
)
