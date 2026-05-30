import Testing

@testable import PluginManifestGen

@Suite("SwiftEmitter")
struct SwiftEmitterTests {

  @Test("empty manifest emits an empty BundledPlugins.all")
  func empty() {
    let out = SwiftEmitter.emit(manifests: [])
    #expect(out.contains("public enum BundledPlugins"))
    #expect(out.contains("public static let all: [PluginManifest] = []"))
  }

  @Test("one manifest emits one entry, fields preserved")
  func oneEntry() {
    let m = Manifest(
      host: "chase.com", pathPrefix: "/web/auth", file: "chase.com/parser.js", displayName: "Chase")
    let out = SwiftEmitter.emit(manifests: [m])
    #expect(out.contains(#"host: "chase.com""#))
    #expect(out.contains(#"pathPrefix: "/web/auth""#))
    #expect(out.contains(#"jsResource: "chase.com/parser""#))  // .js stripped
    #expect(out.contains(#"displayName: "Chase""#))
  }

  @Test("host with quotes is rejected at generation time")
  func rejectsQuoteInHost() {
    let m = Manifest(host: #"evil"com"#, pathPrefix: "/", file: "x.js", displayName: "X")
    #expect(throws: SwiftEmitterError.invalidIdentifier) {
      try SwiftEmitter.emitStrict(manifests: [m])
    }
  }
}
