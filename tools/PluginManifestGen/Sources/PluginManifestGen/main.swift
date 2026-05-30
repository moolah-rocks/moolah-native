import Foundation

let args = CommandLine.arguments
guard args.count == 7 else {
  print(
    """
    usage: PluginManifestGen <plugins.json> <swift-out> <ios-plist-out> \
    <macos-plist-out> <js-entry-in> <js-bundle-out>
    """)
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

// JS bundle: read the hand-maintained dispatcher, then concatenate each
// plugin's parser source (loaded relative to plugins.json) and rewrite the
// placeholder host → class map. A missing parser.js is a hard failure —
// the generator refuses to ship a broken bundle.
let entryURL = URL(fileURLWithPath: args[5])
let entrySource = try String(contentsOf: entryURL, encoding: .utf8)
let pluginsDir = manifestURL.deletingLastPathComponent()
let parsers: [JSBundleEmitter.Parser] = try index.plugins.map { manifest in
  let parserURL = pluginsDir.appendingPathComponent(manifest.file)
  guard FileManager.default.fileExists(atPath: parserURL.path) else {
    FileHandle.standardError.write(
      Data("error: plugin parser not found at \(parserURL.path)\n".utf8))
    exit(3)
  }
  let source = try String(contentsOf: parserURL, encoding: .utf8)
  let className = JSBundleEmitter.className(for: manifest.file)
  return JSBundleEmitter.Parser(host: manifest.host, className: className, source: source)
}
let bundle = JSBundleEmitter.emit(entry: entrySource, parsers: parsers)
try bundle.write(toFile: args[6], atomically: true, encoding: .utf8)
