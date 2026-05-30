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

  @Test("duplicate (host, className) rows emit one map entry and one parser source")
  func deduplicate() {
    // Amex case: two manifest rows (different pathPrefix) → one parser file.
    let entry = #"const plugins = {}; /* GENERATED-PLUGIN-MAP-END */"#
    let parser = "class AmericanexpressImporter { /* … */ }"
    let bundle = JSBundleEmitter.emit(
      entry: entry,
      parsers: [
        .init(
          host: "americanexpress.com", className: "AmericanexpressImporter", source: parser),
        .init(
          host: "americanexpress.com", className: "AmericanexpressImporter", source: parser),
      ])
    // Map has the entry exactly once.
    let mapHits =
      bundle.components(
        separatedBy: #""americanexpress.com": AmericanexpressImporter"#
      ).count - 1
    #expect(mapHits == 1)
    // Parser source appears exactly once.
    let sourceHits = bundle.components(separatedBy: "class AmericanexpressImporter").count - 1
    #expect(sourceHits == 1)
  }

  @Test("sharedScripts are inserted between the dispatcher and the plugin sources")
  func sharedScriptsOrder() {
    let entry = #"const plugins = {}; /* GENERATED-PLUGIN-MAP-END */"#
    let shared = "var MoolahConventions = { tag: \"shared\" };"
    let parser = "class ChaseImporter { /* … */ }"
    let bundle = JSBundleEmitter.emit(
      entry: entry,
      sharedScripts: [shared],
      parsers: [.init(host: "chase.com", className: "ChaseImporter", source: parser)])
    let dispatcherIdx = bundle.range(of: "const plugins = {")!.lowerBound
    let sharedIdx = bundle.range(of: shared)!.lowerBound
    let parserIdx = bundle.range(of: "class ChaseImporter")!.lowerBound
    #expect(dispatcherIdx < sharedIdx)
    #expect(sharedIdx < parserIdx)
  }

  @Test("dispatcher comment that mentions `const plugins = {};` is NOT rewritten")
  func dispatcherCommentSurvives() {
    // The hand-maintained entry file's header comment references the
    // placeholder string verbatim. The emitter must rewrite only the
    // placeholder inside the GENERATED-PLUGIN-MAP marker block — not
    // every occurrence in the source.
    let entry = """
      // rewrites the `const plugins = {};` declaration below
      class MoolahDispatch {
        run() {
          /* GENERATED-PLUGIN-MAP-START */
          const plugins = {};
          /* GENERATED-PLUGIN-MAP-END */
        }
      }
      """
    let parser = "class ChaseImporter {}"
    let bundle = JSBundleEmitter.emit(
      entry: entry,
      parsers: [.init(host: "chase.com", className: "ChaseImporter", source: parser)])
    // The comment preserves the original placeholder text.
    #expect(bundle.contains(#"rewrites the `const plugins = {};` declaration"#))
    // The marker block contains the rewritten map.
    #expect(bundle.contains(#""chase.com": ChaseImporter"#))
    // The pre-rewrite placeholder inside the marker block is gone.
    let mapBlock = bundle.components(separatedBy: "/* GENERATED-PLUGIN-MAP-START */")[1]
      .components(separatedBy: "/* GENERATED-PLUGIN-MAP-END */")[0]
    #expect(!mapBlock.contains("const plugins = {};"))
  }

  @Test("empty sharedScripts behaves the same as the no-argument overload")
  func sharedScriptsDefaultEmpty() {
    let entry = #"const plugins = {}; /* GENERATED-PLUGIN-MAP-END */"#
    let parser = "class ChaseImporter {}"
    let a = JSBundleEmitter.emit(
      entry: entry,
      parsers: [.init(host: "chase.com", className: "ChaseImporter", source: parser)])
    let b = JSBundleEmitter.emit(
      entry: entry,
      sharedScripts: [],
      parsers: [.init(host: "chase.com", className: "ChaseImporter", source: parser)])
    #expect(a == b)
  }
}
