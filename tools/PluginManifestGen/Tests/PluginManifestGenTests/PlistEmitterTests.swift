import Testing

@testable import PluginManifestGen

@Suite("PlistEmitter")
struct PlistEmitterTests {

  @Test("empty manifest emits a predicate that never activates")
  func empty() {
    let xml = PlistEmitter.emit(manifests: [])
    #expect(xml.contains("FALSEPREDICATE"))
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

  @Test("emits the action extension point identifier and principal class")
  func extensionPointAndPrincipal() {
    let xml = PlistEmitter.emit(manifests: [])
    #expect(xml.contains("<key>NSExtensionPointIdentifier</key>"))
    #expect(xml.contains("<string>com.apple.ui-services</string>"))
    #expect(xml.contains("<key>NSExtensionPrincipalClass</key>"))
    #expect(xml.contains("<string>$(PRODUCT_MODULE_NAME).ImportExtensionPrincipal</string>"))
  }

  @Test("emits CFBundle keys with build setting substitutions")
  func cfBundleKeys() {
    let xml = PlistEmitter.emit(manifests: [])
    #expect(xml.contains("<key>CFBundleIdentifier</key>"))
    #expect(xml.contains("<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>"))
    #expect(xml.contains("<key>CFBundleDisplayName</key>"))
    #expect(xml.contains("<string>Import to Moolah</string>"))
  }

  @Test("emits the JavaScript preprocessing file key")
  func javaScriptPreprocessingFile() {
    let xml = PlistEmitter.emit(manifests: [])
    #expect(xml.contains("<key>NSExtensionJavaScriptPreprocessingFile</key>"))
    // Matches the base name of the generated bundle (`extension-entry.bundle.js`).
    #expect(xml.contains("<string>extension-entry.bundle</string>"))
  }
}
