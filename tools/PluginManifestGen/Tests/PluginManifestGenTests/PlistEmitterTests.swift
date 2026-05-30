import Testing

@testable import PluginManifestGen

@Suite("PlistEmitter")
struct PlistEmitterTests {

  @Test("empty manifest emits a predicate that never activates")
  func empty() {
    let xml = PlistEmitter.emit(manifests: [])
    #expect(xml.contains("FALSEPREDICATE") || xml.contains(".@count > 0"))
  }

  @Test("one manifest emits the dotted-suffix host clause")
  func oneEntry() {
    let m = Manifest(
      host: "chase.com", pathPrefix: "/x", file: "chase.com/parser.js", displayName: "Chase")
    let xml = PlistEmitter.emit(manifests: [m])
    #expect(xml.contains(#"$att.URL.host == "chase.com""#))
    #expect(xml.contains(#"$att.URL.host ENDSWITH ".chase.com""#))
    #expect(xml.contains(#"$att.URL.path BEGINSWITH "/x""#))
  }

  @Test("two manifests are OR'd")
  func twoEntries() {
    let a = Manifest(host: "a.com", pathPrefix: "/x", file: "a.js", displayName: "A")
    let b = Manifest(host: "b.com", pathPrefix: "/y", file: "b.js", displayName: "B")
    let xml = PlistEmitter.emit(manifests: [a, b])
    #expect(xml.contains("a.com"))
    #expect(xml.contains("b.com"))
    #expect(xml.contains(" OR "))
  }
}
