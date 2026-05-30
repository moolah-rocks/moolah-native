import Testing

@testable import ImportExtensionKit

@Suite("PluginRegistry.match")
struct PluginRegistryTests {

  private let chase = PluginManifest(
    host: "chase.com", pathPrefix: "/web/auth/dashboard",
    jsResource: "chase.com/parser", displayName: "Chase")
  private let commbank = PluginManifest(
    host: "commbank.com.au", pathPrefix: "/netbank",
    jsResource: "commbank.com.au/parser", displayName: "CommBank")

  private var registry: PluginRegistry { PluginRegistry(manifests: [chase, commbank]) }

  @Test("exact host matches")
  func exactHost() {
    #expect(registry.match(host: "chase.com", path: "/web/auth/dashboard") == chase)
  }

  @Test("dotted subdomain matches")
  func dottedSubdomain() {
    #expect(registry.match(host: "secure.chase.com", path: "/web/auth/dashboard") == chase)
  }

  @Test("look-alike host does NOT match")
  func phishingLookAlike() {
    #expect(registry.match(host: "x-chase.com", path: "/web/auth/dashboard") == nil)
  }

  @Test("matching host with wrong path returns nil")
  func wrongPath() {
    #expect(registry.match(host: "chase.com", path: "/marketing") == nil)
  }

  @Test("path-prefix matches deeper paths")
  func deeperPath() {
    #expect(registry.match(host: "chase.com", path: "/web/auth/dashboard/accounts/12345") == chase)
  }

  @Test("unknown host returns nil")
  func unknownHost() {
    #expect(registry.match(host: "evil.com", path: "/anything") == nil)
  }

  @Test("registry picks the right plugin among many")
  func picksCorrectPlugin() {
    #expect(registry.match(host: "online.commbank.com.au", path: "/netbank/home") == commbank)
  }
}
