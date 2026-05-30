import Testing

@testable import PluginManifestGen

@Suite("JSBundleEmitter")
struct JSBundleEmitterTests {

  @Test("empty manifest leaves dispatcher with empty plugin map")
  func emptyMap() {
    let entry = #"const plugins = {}; /* GENERATED-PLUGIN-MAP-END */"#
    let bundle = JSBundleEmitter.emit(entry: entry, parsers: [])
    #expect(bundle.contains(#"const plugins = {};"#))
  }

  @Test("non-empty manifest produces host → class map and appends parser source")
  func withPlugins() {
    let entry = #"const plugins = {}; /* GENERATED-PLUGIN-MAP-END */"#
    let parserA = "class ChaseImporter { /* … */ }"
    let bundle = JSBundleEmitter.emit(
      entry: entry,
      parsers: [.init(host: "chase.com", className: "ChaseImporter", source: parserA)])
    #expect(bundle.contains(#""chase.com": ChaseImporter"#))
    #expect(bundle.contains("class ChaseImporter"))
  }

  @Test("class name is derived from filename (alpha-numeric, capitalised, Importer suffix)")
  func classNameDerivation() {
    // chase.com/parser.js → ChaseImporter
    #expect(JSBundleEmitter.className(for: "chase.com/parser.js") == "ChaseImporter")
    // commbank.com.au/parser.js → CommbankImporter
    #expect(JSBundleEmitter.className(for: "commbank.com.au/parser.js") == "CommbankImporter")
  }
}
