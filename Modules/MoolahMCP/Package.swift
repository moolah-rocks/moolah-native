// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "MoolahMCP",
  platforms: [.macOS(.v26)],
  products: [.library(name: "MoolahMCP", targets: ["MoolahMCP"])],
  dependencies: [
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk", exact: "0.12.1"),
    .package(url: "https://github.com/hummingbird-project/hummingbird", exact: "2.28.0"),
    .package(url: "https://github.com/apple/swift-nio.git", exact: "2.104.0"),
    .package(url: "https://github.com/apple/swift-nio-extras.git", exact: "1.35.1"),
    .package(url: "https://github.com/apple/swift-log.git", exact: "1.16.1"),
  ],
  targets: [
    .target(
      name: "MoolahMCP",
      dependencies: [
        .product(name: "MCP", package: "swift-sdk"),
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "HummingbirdCore", package: "hummingbird"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
        .product(name: "NIOHTTPTypesHTTP1", package: "swift-nio-extras"),
        .product(name: "Logging", package: "swift-log"),
      ]),
    .testTarget(name: "MoolahMCPTests", dependencies: ["MoolahMCP"]),
  ]
)
