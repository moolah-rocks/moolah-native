import Testing

@testable import ImportExtensionKit

@Suite("ImportExtensionKit smoke")
struct ImportExtensionKitSmokeTests {
  @Test("module is importable")
  func moduleImports() {
    #expect(ImportExtensionKit.frameworkName == "ImportExtensionKit")
  }
}
