import Testing

@testable import PluginManifestGen

@Suite("PlistEmitter")
struct PlistEmitterTests {

  @Test("emits the dict-form web-page activation rule")
  func activationRule() {
    let xml = PlistEmitter.emit()
    #expect(xml.contains("<key>NSExtensionActivationRule</key>"))
    #expect(xml.contains("<key>NSExtensionActivationSupportsWebPageWithMaxCount</key>"))
    #expect(xml.contains("<integer>1</integer>"))
    // Per-host filtering moved to MoolahDispatch in extension-entry.js;
    // the SUBQUERY string-form predicate was silently rejected by the
    // system's predicate parser.
    #expect(!xml.contains("SUBQUERY"))
    #expect(!xml.contains("UTI-CONFORMS-TO"))
  }

  @Test("emits the action extension point identifier and principal class")
  func extensionPointAndPrincipal() {
    let xml = PlistEmitter.emit()
    #expect(xml.contains("<key>NSExtensionPointIdentifier</key>"))
    #expect(xml.contains("<string>com.apple.ui-services</string>"))
    #expect(xml.contains("<key>NSExtensionPrincipalClass</key>"))
    #expect(xml.contains("<string>$(PRODUCT_MODULE_NAME).ImportExtensionPrincipal</string>"))
  }

  @Test("emits CFBundle keys with build setting substitutions")
  func cfBundleKeys() {
    let xml = PlistEmitter.emit()
    #expect(xml.contains("<key>CFBundleIdentifier</key>"))
    #expect(xml.contains("<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>"))
    #expect(xml.contains("<key>CFBundleDisplayName</key>"))
    #expect(xml.contains("<string>Import to Moolah</string>"))
  }

  @Test("emits the JavaScript preprocessing file key")
  func javaScriptPreprocessingFile() {
    let xml = PlistEmitter.emit()
    #expect(xml.contains("<key>NSExtensionJavaScriptPreprocessingFile</key>"))
    // Matches the base name of the generated bundle (`extension-entry.bundle.js`).
    #expect(xml.contains("<string>extension-entry.bundle</string>"))
  }
}
