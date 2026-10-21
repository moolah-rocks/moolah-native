// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "MCPTransportSpike",
  platforms: [.macOS(.v26)],
  dependencies: [
    .package(path: "../../Modules/MoolahMCP"),
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk", exact: "0.12.1"),
  ],
  targets: [
    .executableTarget(
      name: "MCPTransportSpike",
      dependencies: ["MoolahMCP", .product(name: "MCP", package: "swift-sdk")])
  ]
)
