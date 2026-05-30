import Foundation

let args = CommandLine.arguments
guard args.count == 5 else {
  print("usage: PluginManifestGen <plugins.json> <swift-out> <ios-plist-out> <macos-plist-out>")
  exit(2)
}
let manifestURL = URL(fileURLWithPath: args[1])
let data = try Data(contentsOf: manifestURL)
let index = try JSONDecoder().decode(ManifestIndex.self, from: data)

let swift = try SwiftEmitter.emitStrict(manifests: index.plugins)
try swift.write(toFile: args[2], atomically: true, encoding: .utf8)

let plist = PlistEmitter.emit(manifests: index.plugins)
try plist.write(toFile: args[3], atomically: true, encoding: .utf8)
try plist.write(toFile: args[4], atomically: true, encoding: .utf8)
