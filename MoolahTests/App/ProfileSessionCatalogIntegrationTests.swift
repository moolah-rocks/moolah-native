// MoolahTests/App/ProfileSessionCatalogIntegrationTests.swift
import Foundation
import Testing

@testable import Moolah

@MainActor
struct ProfileSessionCatalogIntegrationTests {
  @Test("CloudKit profile exposes a non-nil CoinGecko catalog")
  func cloudKitProfileExposesCatalog() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "ProfileSessionCatalogIntegrationTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let containerManager = try ProfileContainerManager.forTesting()
    let profile = Profile(
      label: "iCloud",
      currencyCode: "AUD",
      financialYearStartMonth: 7
    )
    let session = try ProfileSession(
      resources: ProfileSessionResources(
        networking: ProfileSessionResources.disconnected.networking,
        catalogDirectory: root,
        coinGeckoAPIKey: { nil },
        alchemyAPIKey: { nil },
        removeObsoleteCredential: {},
        rpcEndpoints: InMemoryCryptoRPCEndpointsStore()),
      profile: profile,
      containerManager: containerManager)

    defer { session.cleanupSync(coordinator: nil) }
    #expect(session.coinGeckoCatalog != nil)
  }
}
